# Annotation Reviewer Media Runtime

Portable media runtime builds for [Annotation Reviewer](https://github.com/trhy123/annotation-reviewer).

The goal is to provide `libmpv`, `ffmpeg`, and `ffprobe` as a compact, reproducible, cross-platform runtime instead of bundling independent full-size binary distributions.

## Runtime architecture

The build deliberately uses shared FFmpeg libraries:

```text
shared libavcodec / libavformat / libavfilter / libavutil / libswscale / libswresample
    ├── ffmpeg
    ├── ffprobe
    └── libmpv
```

`libplacebo` and `libass` are built as static dependencies of `libmpv` in this first implementation. x264 is built statically and linked into the shared FFmpeg libraries to provide one predictable H.264 export path without another runtime DLL/dylib/so.

This is **not** a single-file/static runtime: the final package intentionally contains shared dependencies so the three front ends do not duplicate the same FFmpeg code.

## Build targets

- Windows x86-64 (`windows-2025`, MSYS2 UCRT64)
- macOS Apple Silicon arm64 (`macos-15`)
- macOS Intel x86-64 (`macos-15-intel`)
- Linux x86-64 (`ubuntu-22.04`)

The macOS jobs currently set `MACOSX_DEPLOYMENT_TARGET=12.0`, but the first builds should be treated as compatibility candidates rather than a guarantee of macOS 12 support because package-manager-provided transitive libraries also need to be audited.

## Feature scope

The first build uses moderate pruning rather than an extreme codec whitelist.

FFmpeg keeps its native codecs, demuxers, muxers and filters, while removing features that Annotation Reviewer does not need in its bundled runtime, including network protocols, capture devices, `ffplay`, documentation and debug output. External library autodetection is disabled; x264 is enabled explicitly.

libmpv is built as a shared library with the modern render API and OpenGL/plain-GL support. The CLI player, scripting engines, network backend, optical-disc support, archive support, VapourSynth and several optional rendering/output integrations are disabled.

The runtime is intended for local-file playback, frame/PTS inspection, and annotated-video export. More aggressive pruning can be done after the first successful artifacts are tested against real Annotation Reviewer videos.

## Pinned sources

See [`versions.env`](versions.env). The workflow records the resolved source commit IDs in every artifact's `BUILD_INFO.txt`.

## Artifact contents

Each platform artifact contains a directory like:

```text
media-runtime-<platform>/
├── bin/
│   ├── ffmpeg[.exe]
│   └── ffprobe[.exe]
├── lib/ or bin/
│   ├── libmpv / mpv-2.dll
│   ├── libavcodec
│   ├── libavformat
│   ├── libavfilter
│   ├── libavutil
│   ├── libswscale
│   ├── libswresample
│   └── required non-system runtime dependencies
├── include/mpv/
├── licenses/
└── BUILD_INFO.txt
```

Windows places runtime DLLs beside the executables. macOS and Linux keep shared libraries in `lib/` and patch relative runtime search paths.

## Validation

Every job verifies at least:

- `ffmpeg` and `ffprobe` can start from the packaged runtime.
- H.264 MP4 export through `libx264` works.
- `ffprobe` can enumerate per-frame `best_effort_timestamp_time` values.
- a small C program can load/link the libmpv client API and reference the render API.
- packaged shared-library dependencies are recursively collected.

No artifact-size threshold is enforced. File sizes are recorded in `BUILD_INFO.txt` so later pruning can target the components that actually dominate the package.

## Licensing / release status

Because FFmpeg is built with x264 and GPL enabled, these prototype artifacts contain GPL-covered components. Upstream license texts are copied into each artifact. Before using these binaries in a formal public Annotation Reviewer release, the complete transitive dependency set and corresponding redistribution notices should be audited.

The current artifacts are therefore best treated as **experimental runtime candidates** until playback/export regression testing and the license audit are complete.
