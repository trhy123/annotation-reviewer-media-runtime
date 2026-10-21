#!/usr/bin/env python3
"""Reject incomplete or non-portable macOS media runtimes before publishing."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys

SYSTEM_PREFIXES = ("/System/Library/", "/usr/lib/")


def macho_dependencies(path: Path) -> list[str]:
    result = subprocess.run(["otool", "-L", str(path)], check=True, capture_output=True, text=True)
    return [line.strip().split(" (", 1)[0] for line in result.stdout.splitlines()[1:] if line.strip()]


def verify(root: Path) -> list[str]:
    errors: list[str] = []
    lib_dir = root / "lib"
    bin_dir = root / "bin"
    if not lib_dir.is_dir() or not bin_dir.is_dir():
        return ["runtime/bin or runtime/lib is missing"]
    for name in ("ffmpeg", "ffprobe"):
        executable = bin_dir / name
        if not executable.is_file() or not os.access(executable, os.X_OK):
            errors.append(f"missing or non-executable: bin/{name}")
    if not any(lib_dir.glob("libmpv*.dylib")):
        errors.append("no libmpv dylib")
    for item in root.rglob("*"):
        if item.is_symlink():
            target = (item.parent / os.readlink(item)).resolve()
            if not target.is_relative_to(root.resolve()):
                errors.append(f"symlink escapes runtime: {item.relative_to(root)}")
            elif not target.exists():
                errors.append(f"broken symlink: {item.relative_to(root)}")
    for folder in (bin_dir, lib_dir):
        for item in folder.iterdir():
            if item.is_symlink() or not item.is_file():
                continue
            kind = subprocess.run(["file", "-b", str(item)], capture_output=True, text=True, check=True).stdout
            if "Mach-O" not in kind:
                continue
            for dep in macho_dependencies(item):
                if dep.startswith(SYSTEM_PREFIXES):
                    continue
                if dep.startswith("@rpath/"):
                    sibling = (lib_dir / dep.partition("/")[2]).resolve()
                    if sibling.is_file() and sibling.is_relative_to(root.resolve()):
                        continue
                elif dep.startswith("@loader_path/"):
                    target = (item.parent / dep[len("@loader_path/"):]).resolve()
                    if target.is_file() and target.is_relative_to(root.resolve()):
                        continue
                elif dep.startswith("@executable_path/") and folder == bin_dir:
                    target = (bin_dir / dep[len("@executable_path/"):]).resolve()
                    if target.is_file() and target.is_relative_to(root.resolve()):
                        continue
                errors.append(f"{item.relative_to(root)}: unresolved or external dependency {dep}")
    return errors


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_macos_runtime.py PATH_TO_RUNTIME", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    failures = verify(root)
    if failures:
        for failure in failures:
            print("ERROR: " + failure, file=sys.stderr)
        return 1
    print("macOS runtime dependency and symlink audit passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
