#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${1:-}"
MAX_MINOS="${2:-${MACOSX_DEPLOYMENT_TARGET:-}}"

if [[ -z "${RUNTIME_DIR}" || -z "${MAX_MINOS}" ]]; then
  echo "usage: $0 <runtime-dir> <maximum-macos-version>" >&2
  exit 2
fi
if [[ ! -d "${RUNTIME_DIR}" ]]; then
  echo "runtime directory not found: ${RUNTIME_DIR}" >&2
  exit 2
fi
command -v otool >/dev/null 2>&1 || { echo "otool is required" >&2; exit 2; }
command -v file >/dev/null 2>&1 || { echo "file is required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }

version_le() {
  python3 - "$1" "$2" <<'PY'
import re
import sys

def parse(value: str) -> tuple[int, ...]:
    parts = [int(x) for x in re.findall(r"\d+", value)]
    return tuple((parts + [0, 0, 0])[:3])

raise SystemExit(0 if parse(sys.argv[1]) <= parse(sys.argv[2]) else 1)
PY
}

extract_minos() {
  otool -l "$1" 2>/dev/null | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { mode = "build"; next }
    $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { mode = "legacy"; next }
    mode == "build" && $1 == "minos" { print $2; mode = ""; next }
    mode == "legacy" && $1 == "version" { print $2; mode = ""; next }
  '
}

checked=0
failures=0
while IFS= read -r -d '' path; do
  if ! file -b "${path}" | grep -q 'Mach-O'; then
    continue
  fi
  checked=$((checked + 1))
  mapfile -t versions < <(extract_minos "${path}" | sort -u)
  rel="${path#${RUNTIME_DIR}/}"
  if [[ "${#versions[@]}" -eq 0 ]]; then
    echo "ERROR: no macOS minimum-version load command found: ${rel}" >&2
    failures=$((failures + 1))
    continue
  fi
  for minos in "${versions[@]}"; do
    printf '%-56s minos=%s\n' "${rel}" "${minos}"
    if ! version_le "${minos}" "${MAX_MINOS}"; then
      echo "ERROR: ${rel} requires macOS ${minos}, exceeds declared ${MAX_MINOS}" >&2
      failures=$((failures + 1))
    fi
  done
done < <(find "${RUNTIME_DIR}/bin" "${RUNTIME_DIR}/lib" -type f -print0 2>/dev/null)

if [[ "${checked}" -eq 0 ]]; then
  echo "ERROR: no Mach-O files found under ${RUNTIME_DIR}/bin or ${RUNTIME_DIR}/lib" >&2
  exit 1
fi
if [[ "${failures}" -ne 0 ]]; then
  echo "macOS compatibility audit failed: ${failures} incompatible or unauditable load commands." >&2
  exit 1
fi

echo "macOS compatibility audit passed: ${checked} Mach-O files require no newer than macOS ${MAX_MINOS}."
