#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  echo "usage: $0 <windows-amd64|macos-arm64|macos-amd64|linux-amd64>" >&2
  exit 2
fi

case "${TARGET}" in
  windows-amd64|macos-arm64|macos-amd64|linux-amd64) ;;
  *) echo "unsupported target: ${TARGET}" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"

WORK="${ROOT}/.work/${TARGET}"
SRC="${WORK}/src"
PREFIX="${WORK}/prefix"
DEPS="${WORK}/deps"
DIST_ROOT="${ROOT}/dist"
DIST="${DIST_ROOT}/media-runtime-${TARGET}"

rm -rf "${WORK}" "${DIST}"
mkdir -p "${SRC}" "${PREFIX}" "${DEPS}" "${DIST_ROOT}"

if command -v nproc >/dev/null 2>&1; then
  JOBS="$(nproc)"
elif command -v sysctl >/dev/null 2>&1; then
  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
else
  JOBS=4
fi

export CFLAGS="${CFLAGS:-} -O2 -fPIC"
export CXXFLAGS="${CXXFLAGS:-} -O2 -fPIC"
export CPPFLAGS="-I${DEPS}/include ${CPPFLAGS:-}"
export LDFLAGS="-L${DEPS}/lib ${LDFLAGS:-}"

PKG_PATHS=("${PREFIX}/lib/pkgconfig" "${DEPS}/lib/pkgconfig")
if [[ "${TARGET}" == windows-* ]]; then
  PKG_PATHS+=("/ucrt64/lib/pkgconfig" "/ucrt64/share/pkgconfig")
elif [[ "${TARGET}" == macos-* ]]; then
  export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
  if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX="$(brew --prefix)"
    PKG_PATHS+=("${BREW_PREFIX}/lib/pkgconfig" "${BREW_PREFIX}/share/pkgconfig")
    for formula in freetype fribidi harfbuzz; do
      formula_prefix="$(brew --prefix "${formula}" 2>/dev/null || true)"
      [[ -n "${formula_prefix}" ]] && PKG_PATHS+=("${formula_prefix}/lib/pkgconfig")
    done
  fi
fi

PKG_CONFIG_PATH_JOINED=""
for p in "${PKG_PATHS[@]}"; do
  if [[ -d "${p}" ]]; then
    if [[ -n "${PKG_CONFIG_PATH_JOINED}" ]]; then
      PKG_CONFIG_PATH_JOINED+="${PKG_CONFIG_PATH_JOINED:+:}${p}"
    else
      PKG_CONFIG_PATH_JOINED="${p}"
    fi
  fi
done
if [[ -n "${PKG_CONFIG_PATH:-}" ]]; then
  PKG_CONFIG_PATH_JOINED+="${PKG_CONFIG_PATH_JOINED:+:}${PKG_CONFIG_PATH}"
fi
export PKG_CONFIG_PATH="${PKG_CONFIG_PATH_JOINED}"

clone_ref() {
  local url="$1" ref="$2" dst="$3"
  rm -rf "${dst}"
  git init -q "${dst}"
  git -C "${dst}" remote add origin "${url}"
  git -C "${dst}" fetch -q --depth 1 origin "${ref}"
  git -C "${dst}" checkout -q --detach FETCH_HEAD
}

section() {
  printf '\n===== %s =====\n' "$*"
}

section "Fetch sources"
clone_ref https://github.com/mirror/x264.git "${X264_REF}" "${SRC}/x264"
clone_ref https://github.com/libass/libass.git "${LIBASS_REF}" "${SRC}/libass"
clone_ref https://github.com/haasn/libplacebo.git "${LIBPLACEBO_REF}" "${SRC}/libplacebo"
clone_ref https://github.com/FFmpeg/FFmpeg.git "${FFMPEG_REF}" "${SRC}/ffmpeg"
clone_ref https://github.com/mpv-player/mpv.git "${MPV_REF}" "${SRC}/mpv"

git -C "${SRC}/libplacebo" submodule update -q --init --recursive --depth 1 || true

section "Build x264 (static)"
pushd "${SRC}/x264" >/dev/null
X264_ARGS=(
  "--prefix=${DEPS}"
  --enable-static
  --disable-cli
  --enable-pic
  --disable-opencl
)
if [[ "${TARGET}" == windows-* ]]; then
  X264_ARGS+=(--host=x86_64-w64-mingw32)
fi
./configure "${X264_ARGS[@]}"
make -j"${JOBS}"
make install
popd >/dev/null

section "Build libass (static)"
LIBASS_PLATFORM_ARGS=(-Dfontconfig=disabled -Ddirectwrite=disabled -Dcoretext=disabled)
case "${TARGET}" in
  windows-amd64) LIBASS_PLATFORM_ARGS=(-Dfontconfig=disabled -Ddirectwrite=enabled -Dcoretext=disabled) ;;
  macos-*)       LIBASS_PLATFORM_ARGS=(-Dfontconfig=disabled -Ddirectwrite=disabled -Dcoretext=enabled) ;;
  linux-amd64)   LIBASS_PLATFORM_ARGS=(-Dfontconfig=enabled -Ddirectwrite=disabled -Dcoretext=disabled) ;;
esac
meson setup "${SRC}/libass/build" "${SRC}/libass" \
  --prefix="${DEPS}" \
  --libdir=lib \
  --buildtype=release \
  --default-library=static \
  -Db_lto=true \
  -Dtest=disabled \
  -Dcompare=disabled \
  -Dprofile=disabled \
  -Dfuzz=disabled \
  -Dcheckasm=disabled \
  -Dlibunibreak=disabled \
  "${LIBASS_PLATFORM_ARGS[@]}"
meson compile -C "${SRC}/libass/build" -j "${JOBS}"
meson install -C "${SRC}/libass/build"

section "Build libplacebo (static OpenGL)"
meson setup "${SRC}/libplacebo/build" "${SRC}/libplacebo" \
  --prefix="${DEPS}" \
  --libdir=lib \
  --buildtype=release \
  --default-library=static \
  -Db_lto=true \
  -Dvulkan=disabled \
  -Dopengl=enabled \
  -Dgl-proc-addr=enabled \
  -Dd3d11=disabled \
  -Dglslang=disabled \
  -Dshaderc=disabled \
  -Dlcms=disabled \
  -Ddovi=disabled \
  -Dlibdovi=disabled \
  -Ddemos=false \
  -Dtests=false \
  -Dbench=false \
  -Dfuzz=false \
  -Dunwind=disabled \
  -Dxxhash=disabled
meson compile -C "${SRC}/libplacebo/build" -j "${JOBS}"
meson install -C "${SRC}/libplacebo/build"

section "Build FFmpeg/ffprobe with shared libav*"
pushd "${SRC}/ffmpeg" >/dev/null
FF_EXTRA_ARGS=()
if [[ "${TARGET}" == linux-* ]]; then
  FF_EXTRA_ARGS+=(--enable-vaapi --enable-libdrm)
fi
./configure \
  --prefix="${PREFIX}" \
  --enable-shared \
  --disable-static \
  --enable-gpl \
  --enable-libx264 \
  --disable-autodetect \
  --disable-debug \
  --disable-doc \
  --disable-ffplay \
  --disable-avdevice \
  --disable-network \
  --enable-pic \
  --pkg-config-flags=--static \
  --extra-cflags="-I${DEPS}/include" \
  --extra-ldflags="-L${DEPS}/lib" \
  "${FF_EXTRA_ARGS[@]}"
make -j"${JOBS}"
make install
popd >/dev/null

# Make sure mpv finds our just-built shared FFmpeg first, and our static
# libass/libplacebo before anything supplied by the runner.
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${DEPS}/lib/pkgconfig:${PKG_CONFIG_PATH}"

section "Build shared libmpv against the same shared FFmpeg"
MPV_PLATFORM_ARGS=()
case "${TARGET}" in
  windows-amd64)
    MPV_PLATFORM_ARGS+=(
      -Dwin32-smtc=disabled
      -Dwasapi=disabled
      # libplacebo v7 contains C++20 code, while the shared mpv target is
      # linked through the C compiler on MinGW. Add the C++ runtime explicitly.
      -Dc_link_args=-lstdc++
    )
    ;;
  macos-*)
    MPV_PLATFORM_ARGS+=(
      -Dmacos-media-player=disabled
      -Dmacos-touchbar=disabled
    )
    ;;
  linux-amd64)
    MPV_PLATFORM_ARGS+=(
      -Djack=disabled
      -Dpipewire=disabled
      -Dpulse=disabled
      # libplacebo v7 contains C++20 code, but mpv is linked by the C driver.
      -Dc_link_args=-lstdc++
    )
    ;;
esac

meson setup "${SRC}/mpv/build" "${SRC}/mpv" \
  --prefix="${PREFIX}" \
  --libdir=lib \
  --buildtype=release \
  --default-library=shared \
  --wrap-mode=nodownload \
  -Db_lto=true \
  -Dgpl=true \
  -Dcplayer=false \
  -Dlibmpv=true \
  -Dtests=false \
  -Dfuzzers=false \
  -Dbuild-date=false \
  -Dplain-gl=enabled \
  -Dgl=enabled \
  -Dvulkan=disabled \
  -Dshaderc=disabled \
  -Dspirv-cross=disabled \
  -Dlua=disabled \
  -Djavascript=disabled \
  -Dcplugins=disabled \
  -Dlibarchive=disabled \
  -Dlibavdevice=disabled \
  -Dlibbluray=disabled \
  -Ddvdnav=disabled \
  -Dcdda=disabled \
  -Ddvbin=disabled \
  -Dvapoursynth=disabled \
  -Drubberband=disabled \
  -Dzimg=disabled \
  -Duchardet=disabled \
  -Dlcms2=disabled \
  -Djpeg=disabled \
  -Dsdl2-video=disabled \
  -Dsdl2-audio=disabled \
  -Dopenal=disabled \
  -Dhtml-build=disabled \
  -Dmanpage-build=disabled \
  -Dpdf-build=disabled \
  "${MPV_PLATFORM_ARGS[@]}"
meson compile -C "${SRC}/mpv/build" -j "${JOBS}"
meson install -C "${SRC}/mpv/build"

section "Prefix smoke tests"
export PATH="${PREFIX}/bin:${PATH}"
if [[ "${TARGET}" == macos-* ]]; then
  export DYLD_LIBRARY_PATH="${PREFIX}/lib:${DYLD_LIBRARY_PATH:-}"
elif [[ "${TARGET}" == linux-* ]]; then
  export LD_LIBRARY_PATH="${PREFIX}/lib:${LD_LIBRARY_PATH:-}"
fi

"${PREFIX}/bin/ffmpeg" -hide_banner -version | head -n 3
"${PREFIX}/bin/ffprobe" -hide_banner -version | head -n 3

CC_BIN="$(command -v cc || command -v gcc)"
SMOKE_BIN="${WORK}/mpv_smoke"
[[ "${TARGET}" == windows-* ]] && SMOKE_BIN+=".exe"
"${CC_BIN}" "${ROOT}/tests/mpv_smoke.c" -o "${SMOKE_BIN}" \
  $(pkg-config --cflags --libs mpv)
"${SMOKE_BIN}"

RAW="${WORK}/sample.rgb"
SAMPLE_MP4="${WORK}/sample.mp4"
dd if=/dev/zero of="${RAW}" bs=61440 count=1 status=none
"${PREFIX}/bin/ffmpeg" -hide_banner -loglevel error -y \
  -f rawvideo -pixel_format rgb24 -video_size 64x64 -framerate 5 \
  -i "${RAW}" -frames:v 5 -an -c:v libx264 -preset veryfast -crf 30 \
  -pix_fmt yuv420p "${SAMPLE_MP4}"
PTS_FILE="${WORK}/pts.txt"
"${PREFIX}/bin/ffprobe" -v error -select_streams v:0 -show_frames \
  -show_entries frame=best_effort_timestamp_time -of csv=p=0 \
  "${SAMPLE_MP4}" > "${PTS_FILE}"
PTS_COUNT="$(grep -Ec '[0-9]' "${PTS_FILE}" || true)"
if [[ "${PTS_COUNT}" -lt 5 ]]; then
  echo "ffprobe PTS smoke test failed: expected >=5 frame timestamps, got ${PTS_COUNT}" >&2
  cat "${PTS_FILE}" >&2 || true
  exit 1
fi

section "Bundle portable runtime"
bash "${ROOT}/scripts/bundle_runtime.sh" "${TARGET}" "${PREFIX}" "${DEPS}" "${DIST}"

mkdir -p "${DIST}/licenses"
cp "${SRC}/ffmpeg/COPYING.GPLv2" "${DIST}/licenses/FFmpeg-GPLv2.txt"
cp "${SRC}/mpv/LICENSE.GPL" "${DIST}/licenses/mpv-GPL.txt"
cp "${SRC}/libplacebo/LICENSE" "${DIST}/licenses/libplacebo-LICENSE.txt"
cp "${SRC}/libass/COPYING" "${DIST}/licenses/libass-COPYING.txt"
cp "${SRC}/x264/COPYING" "${DIST}/licenses/x264-COPYING.txt"
cat > "${DIST}/licenses/NOTICE.txt" <<'EOF'
This artifact is an experimental build for Annotation Reviewer.
The principal upstream license files are included here. Runtime dependencies
recursively copied from the platform toolchain/package manager may require
additional notices. Perform a complete transitive license audit before using
these artifacts in a formal public software release.
EOF

section "Packaged-runtime smoke tests"
if [[ "${TARGET}" == windows-* ]]; then
  RUNTIME_FFMPEG="${DIST}/bin/ffmpeg.exe"
  RUNTIME_FFPROBE="${DIST}/bin/ffprobe.exe"
  export PATH="${DIST}/bin:${PATH}"
elif [[ "${TARGET}" == macos-* ]]; then
  RUNTIME_FFMPEG="${DIST}/bin/ffmpeg"
  RUNTIME_FFPROBE="${DIST}/bin/ffprobe"
  unset DYLD_LIBRARY_PATH || true
else
  RUNTIME_FFMPEG="${DIST}/bin/ffmpeg"
  RUNTIME_FFPROBE="${DIST}/bin/ffprobe"
  unset LD_LIBRARY_PATH || true
fi

"${RUNTIME_FFMPEG}" -hide_banner -version | head -n 3
"${RUNTIME_FFPROBE}" -hide_banner -version | head -n 3

PACKAGED_MP4="${WORK}/packaged-sample.mp4"
"${RUNTIME_FFMPEG}" -hide_banner -loglevel error -y \
  -f rawvideo -pixel_format rgb24 -video_size 64x64 -framerate 5 \
  -i "${RAW}" -frames:v 5 -an -c:v libx264 -preset veryfast -crf 30 \
  -pix_fmt yuv420p "${PACKAGED_MP4}"
"${RUNTIME_FFPROBE}" -v error -select_streams v:0 -show_frames \
  -show_entries frame=best_effort_timestamp_time -of csv=p=0 \
  "${PACKAGED_MP4}" > "${WORK}/packaged-pts.txt"
PACKAGED_PTS_COUNT="$(grep -Ec '[0-9]' "${WORK}/packaged-pts.txt" || true)"
if [[ "${PACKAGED_PTS_COUNT}" -lt 5 ]]; then
  echo "packaged ffprobe PTS smoke test failed" >&2
  exit 1
fi

# Re-run the libmpv test against the packaged dependency search path.
if [[ "${TARGET}" == windows-* ]]; then
  PATH="${DIST}/bin:${PATH}" "${SMOKE_BIN}"
elif [[ "${TARGET}" == macos-* ]]; then
  DYLD_LIBRARY_PATH="${DIST}/lib" "${SMOKE_BIN}"
else
  LD_LIBRARY_PATH="${DIST}/lib" "${SMOKE_BIN}"
fi

section "Write build metadata"
{
  echo "Annotation Reviewer Media Runtime"
  echo "target=${TARGET}"
  echo "mpv_ref=${MPV_REF}"
  echo "mpv_commit=$(git -C "${SRC}/mpv" rev-parse HEAD)"
  echo "ffmpeg_ref=${FFMPEG_REF}"
  echo "ffmpeg_commit=$(git -C "${SRC}/ffmpeg" rev-parse HEAD)"
  echo "libplacebo_ref=${LIBPLACEBO_REF}"
  echo "libplacebo_commit=$(git -C "${SRC}/libplacebo" rev-parse HEAD)"
  echo "libass_ref=${LIBASS_REF}"
  echo "libass_commit=$(git -C "${SRC}/libass" rev-parse HEAD)"
  echo "x264_ref=${X264_REF}"
  echo "x264_commit=$(git -C "${SRC}/x264" rev-parse HEAD)"
  echo "compiler=$(${CC_BIN} --version | head -n 1)"
  echo "system=$(uname -a)"
  echo ""
  echo "ffmpeg:"
  "${RUNTIME_FFMPEG}" -hide_banner -version | head -n 10
  echo ""
  echo "ffprobe PTS smoke frames=${PACKAGED_PTS_COUNT}"
  echo ""
  echo "files (bytes):"
  find "${DIST}" -type f | sort | while IFS= read -r f; do
    bytes="$(wc -c < "${f}" | tr -d ' ')"
    rel="${f#${DIST}/}"
    printf '%12s  %s\n' "${bytes}" "${rel}"
  done
} > "${DIST}/BUILD_INFO.txt"

size_kib="$(du -sk "${DIST}" | awk '{print $1}')"
echo "Runtime directory size: ${size_kib} KiB"
echo "Built: ${DIST}"
