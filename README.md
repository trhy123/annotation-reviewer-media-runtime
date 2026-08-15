# Annotation Reviewer Media Runtime

Portable shared media runtimes for [Annotation Reviewer](https://github.com/trhy123/annotation-reviewer).

The build provides `libmpv`, `ffmpeg`, and `ffprobe` against one shared FFmpeg dependency set instead of shipping separate full-size distributions.

## Runtime architecture

```text
shared libavcodec / libavformat / libavfilter / libavutil / libswscale / libswresample
    ├── ffmpeg
    ├── ffprobe
    └── libmpv
```

`libplacebo` and `libass` are built as static libmpv dependencies. x264 is built statically and linked into the shared FFmpeg libraries for H.264 export.

## Build targets

- Windows x86-64 (`windows-2025`)
- macOS 13+ Apple Silicon arm64 (`macos-15`)
- macOS 13+ Intel x86-64 (`macos-15-intel`)
- Linux x86-64 (`ubuntu-22.04`)

There is no separate legacy macOS 12 runtime. Both macOS jobs declare `MACOSX_DEPLOYMENT_TARGET=13.0`, and every packaged Mach-O executable/library is audited before release. A package fails if any bundled binary requires a newer macOS version than declared.

## Final packages

Release assets are named only by platform:

```text
windows-amd64.7z
macos-arm64.tar.xz
macos-amd64.tar.xz
linux-amd64.tar.xz
```

Every archive contains exactly one top-level directory named `runtime`:

```text
runtime/
├── bin/
│   ├── ffmpeg[.exe]
│   └── ffprobe[.exe]
├── lib/                 # macOS/Linux only
│   ├── libmpv
│   ├── libavcodec
│   ├── libavformat
│   ├── libavfilter
│   ├── libavutil
│   ├── libswscale
│   ├── libswresample
│   └── required non-system runtime dependencies
├── licenses/
├── BUILD_INFO.txt
└── DEPENDENCIES.txt
```

Windows keeps `libmpv` and all runtime DLL dependencies beside `ffmpeg.exe` and `ffprobe.exe` in `runtime/bin/`. Development headers such as `include/mpv/` are intentionally excluded from release packages.

## Feature scope

The build uses moderate pruning rather than an extreme codec whitelist. FFmpeg keeps its native codecs, demuxers, muxers and filters while removing network protocols, capture devices, `ffplay`, documentation and debug output. External library autodetection is disabled; x264 is enabled explicitly.

libmpv is built as a shared library with the render API and OpenGL/plain-GL support. The CLI player, scripting engines, optical-disc support, archive support, VapourSynth and several optional rendering/output integrations are disabled.

## Validation

Every platform build verifies that:

- packaged `ffmpeg` and `ffprobe` start successfully;
- H.264 MP4 export through `libx264` works;
- `ffprobe` enumerates per-frame `best_effort_timestamp_time` values;
- a small C program loads/links the libmpv client and render APIs;
- required non-system shared-library dependencies are recursively bundled;
- macOS binaries do not exceed the declared deployment target.

Resolved source commits and file sizes are recorded in `BUILD_INFO.txt`.

## Licensing

FFmpeg is built with x264 and GPL enabled, so these runtimes contain GPL-covered components. Upstream license texts are included. A complete transitive redistribution/license audit should be completed before a formal public software release.
