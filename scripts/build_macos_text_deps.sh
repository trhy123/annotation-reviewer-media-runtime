#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/versions.env"

PREFIX="${1:-${ROOT}/.macos-text-deps}"
SRC="${ROOT}/.macos-text-src"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export CFLAGS="${CFLAGS:-} -O2 -fPIC -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export CXXFLAGS="${CXXFLAGS:-} -O2 -fPIC -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
export LDFLAGS="-L${PREFIX}/lib -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} ${LDFLAGS:-}"
export CPPFLAGS="-I${PREFIX}/include ${CPPFLAGS:-}"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/share/pkgconfig"

rm -rf "${PREFIX}" "${SRC}"
mkdir -p "${PREFIX}" "${SRC}"

clone_ref() {
  local url="$1" ref="$2" dst="$3"
  git init -q "${dst}"
  git -C "${dst}" remote add origin "${url}"
  git -C "${dst}" fetch -q --depth 1 origin "${ref}"
  git -C "${dst}" checkout -q --detach FETCH_HEAD
}

clone_ref https://github.com/freetype/freetype.git "${FREETYPE_REF}" "${SRC}/freetype"
clone_ref https://github.com/fribidi/fribidi.git "${FRIBIDI_REF}" "${SRC}/fribidi"
clone_ref https://github.com/harfbuzz/harfbuzz.git "${HARFBUZZ_REF}" "${SRC}/harfbuzz"

meson setup "${SRC}/freetype/build" "${SRC}/freetype" \
  --prefix="${PREFIX}" --libdir=lib --buildtype=release \
  --default-library=static --wrap-mode=nodownload -Db_staticpic=true \
  -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled \
  -Dpng=disabled -Dzlib=disabled -Dtests=disabled
meson compile -C "${SRC}/freetype/build" -j "${JOBS}"
meson install -C "${SRC}/freetype/build"

meson setup "${SRC}/fribidi/build" "${SRC}/fribidi" \
  --prefix="${PREFIX}" --libdir=lib --buildtype=release \
  --default-library=static --wrap-mode=nodownload -Db_staticpic=true \
  -Ddocs=false -Dbin=false -Dtests=false
meson compile -C "${SRC}/fribidi/build" -j "${JOBS}"
meson install -C "${SRC}/fribidi/build"

meson setup "${SRC}/harfbuzz/build" "${SRC}/harfbuzz" \
  --prefix="${PREFIX}" --libdir=lib --buildtype=release \
  --default-library=static --wrap-mode=nodownload -Db_staticpic=true \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled \
  -Dpng=disabled -Dzlib=disabled -Dicu=disabled -Dgraphite2=disabled \
  -Dfreetype=disabled -Dfontations=disabled -Dgdi=disabled \
  -Ddirectwrite=disabled -Dcoretext=disabled -Dharfrust=disabled \
  -Dkbts=disabled -Dwasm=disabled -Draster=disabled -Dvector=disabled \
  -Dgpu=disabled -Dgpu_demo=disabled -Dsubset=disabled \
  -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled \
  -Dutilities=disabled -Dbenchmark=disabled
meson compile -C "${SRC}/harfbuzz/build" -j "${JOBS}"
meson install -C "${SRC}/harfbuzz/build"

mkdir -p "${PREFIX}/licenses"
cp "${SRC}/freetype/LICENSE.TXT" "${PREFIX}/licenses/FreeType-LICENSE.txt"
cp "${SRC}/fribidi/COPYING" "${PREFIX}/licenses/FriBidi-COPYING.txt"
cp "${SRC}/harfbuzz/COPYING" "${PREFIX}/licenses/HarfBuzz-COPYING.txt"

for pc in freetype2 fribidi harfbuzz; do
  actual="$(pkg-config --variable=prefix "${pc}")"
  if [[ "${actual}" != "${PREFIX}" ]]; then
    echo "Unexpected ${pc} pkg-config prefix: ${actual}" >&2
    exit 1
  fi
done

printf 'Built static macOS text dependencies for macOS %s at %s\n' \
  "${MACOSX_DEPLOYMENT_TARGET}" "${PREFIX}"
