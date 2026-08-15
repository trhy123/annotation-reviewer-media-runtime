#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
PREFIX="${2:-}"
DEPS="${3:-}"
DIST="${4:-}"

if [[ -z "${TARGET}" || -z "${PREFIX}" || -z "${DEPS}" || -z "${DIST}" ]]; then
  echo "usage: $0 <target> <prefix> <static-deps-prefix> <dist-dir>" >&2
  exit 2
fi

rm -rf "${DIST}"
mkdir -p "${DIST}/bin" "${DIST}/licenses"

copy_glob() {
  local destination="$1"
  shift
  local pattern f
  shopt -s nullglob
  for pattern in "$@"; do
    for f in ${pattern}; do
      [[ -f "${f}" || -L "${f}" ]] || continue
      cp -a "${f}" "${destination}/"
    done
  done
  shopt -u nullglob
}

is_windows_system_dll() {
  local name="${1,,}"
  case "${name}" in
    kernel32.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|uuid.dll|comdlg32.dll|comctl32.dll|shlwapi.dll|ws2_32.dll|bcrypt.dll|crypt32.dll|secur32.dll|version.dll|winmm.dll|imm32.dll|setupapi.dll|dwmapi.dll|uxtheme.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|opengl32.dll|glu32.dll|d3d11.dll|dxgi.dll|d3d9.dll|mf.dll|mfplat.dll|mfuuid.dll|propsys.dll|powrprof.dll|cfgmgr32.dll|iphlpapi.dll|normaliz.dll|wldap32.dll|dbghelp.dll|wintrust.dll|rpcrt4.dll|userenv.dll|windows.storage.dll|api-ms-win-*.dll|ext-ms-win-*.dll)
      return 0 ;;
  esac
  return 1
}

bundle_windows() {
  command -v objdump >/dev/null 2>&1 || { echo "objdump is required" >&2; exit 1; }

  copy_glob "${DIST}/bin" \
    "${PREFIX}/bin/ffmpeg.exe" \
    "${PREFIX}/bin/ffprobe.exe" \
    "${PREFIX}/bin/mpv-*.dll" \
    "${PREFIX}/bin/libmpv*.dll" \
    "${PREFIX}/bin/avcodec-*.dll" \
    "${PREFIX}/bin/avformat-*.dll" \
    "${PREFIX}/bin/avfilter-*.dll" \
    "${PREFIX}/bin/avutil-*.dll" \
    "${PREFIX}/bin/swscale-*.dll" \
    "${PREFIX}/bin/swresample-*.dll"

  [[ -f "${DIST}/bin/ffmpeg.exe" ]] || { echo "ffmpeg.exe was not installed" >&2; exit 1; }
  [[ -f "${DIST}/bin/ffprobe.exe" ]] || { echo "ffprobe.exe was not installed" >&2; exit 1; }
  compgen -G "${DIST}/bin/*mpv*.dll" >/dev/null || { echo "libmpv DLL was not installed" >&2; exit 1; }

  local roots=("${PREFIX}/bin" "${DEPS}/bin" "/ucrt64/bin")
  local changed=1 file dep root candidate
  while [[ "${changed}" -eq 1 ]]; do
    changed=0
    while IFS= read -r -d '' file; do
      while IFS= read -r dep; do
        dep="${dep//$'\r'/}"
        [[ -n "${dep}" ]] || continue
        if is_windows_system_dll "${dep}"; then
          continue
        fi
        if [[ -e "${DIST}/bin/${dep}" ]]; then
          continue
        fi

        candidate=""
        for root in "${roots[@]}"; do
          [[ -d "${root}" ]] || continue
          candidate="$(find "${root}" -maxdepth 1 -type f -iname "${dep}" -print -quit 2>/dev/null || true)"
          [[ -n "${candidate}" ]] && break
        done

        if [[ -n "${candidate}" ]]; then
          cp -L "${candidate}" "${DIST}/bin/${dep}"
          echo "Bundled Windows dependency: ${dep}"
          changed=1
        else
          echo "Windows dependency not bundled (assumed system/optional): ${dep}" >&2
        fi
      done < <(objdump -p "${file}" 2>/dev/null | sed -n 's/^.*DLL Name: //p')
    done < <(find "${DIST}/bin" -maxdepth 1 -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0)
  done

  if command -v strip >/dev/null 2>&1; then
    find "${DIST}/bin" -maxdepth 1 -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0 |
      while IFS= read -r -d '' f; do strip --strip-unneeded "${f}" 2>/dev/null || true; done
  fi

  {
    echo "Windows PE dependencies after bundling"
    echo
    while IFS= read -r -d '' file; do
      echo "[$(basename "${file}")]"
      objdump -p "${file}" 2>/dev/null | sed -n 's/^.*DLL Name: /  /p' | sort -fu
      echo
    done < <(find "${DIST}/bin" -maxdepth 1 -type f \( -iname '*.exe' -o -iname '*.dll' \) -print0 | sort -z)
  } > "${DIST}/DEPENDENCIES.txt"
}

is_linux_system_lib() {
  local name="$1"
  case "${name}" in
    linux-vdso.so*|ld-linux*.so*|ld-musl-*.so*|libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|libresolv.so*|libutil.so*|libnsl.so*) return 0 ;;
  esac
  return 1
}

linux_ldd_paths() {
  local file="$1"
  LD_LIBRARY_PATH="${DIST}/lib:${PREFIX}/lib:${LD_LIBRARY_PATH:-}" ldd "${file}" 2>/dev/null |
    awk '
      /=> \/[^ ]+/ {print $3}
      /^\s*\// {print $1}
    ' | sort -u
}

bundle_linux() {
  command -v ldd >/dev/null 2>&1 || { echo "ldd is required" >&2; exit 1; }
  command -v patchelf >/dev/null 2>&1 || { echo "patchelf is required" >&2; exit 1; }

  mkdir -p "${DIST}/lib"
  copy_glob "${DIST}/bin" "${PREFIX}/bin/ffmpeg" "${PREFIX}/bin/ffprobe"
  copy_glob "${DIST}/lib" \
    "${PREFIX}/lib/libmpv.so*" \
    "${PREFIX}/lib/libavcodec.so*" \
    "${PREFIX}/lib/libavformat.so*" \
    "${PREFIX}/lib/libavfilter.so*" \
    "${PREFIX}/lib/libavutil.so*" \
    "${PREFIX}/lib/libswscale.so*" \
    "${PREFIX}/lib/libswresample.so*"

  [[ -f "${DIST}/bin/ffmpeg" ]] || { echo "ffmpeg was not installed" >&2; exit 1; }
  compgen -G "${DIST}/lib/libmpv.so*" >/dev/null || { echo "libmpv.so was not installed" >&2; exit 1; }

  local changed=1 file path name
  while [[ "${changed}" -eq 1 ]]; do
    changed=0
    while IFS= read -r -d '' file; do
      while IFS= read -r path; do
        [[ -f "${path}" || -L "${path}" ]] || continue
        name="$(basename "${path}")"
        if is_linux_system_lib "${name}" || [[ -e "${DIST}/lib/${name}" ]]; then
          continue
        fi
        cp -L "${path}" "${DIST}/lib/${name}"
        echo "Bundled Linux dependency: ${name}"
        changed=1
      done < <(linux_ldd_paths "${file}")
    done < <(find "${DIST}/bin" "${DIST}/lib" -maxdepth 1 -type f -print0)
  done

  while IFS= read -r -d '' f; do
    patchelf --set-rpath '$ORIGIN/../lib' "${f}"
  done < <(find "${DIST}/bin" -maxdepth 1 -type f -print0)
  while IFS= read -r -d '' f; do
    patchelf --set-rpath '$ORIGIN' "${f}" 2>/dev/null || true
  done < <(find "${DIST}/lib" -maxdepth 1 -type f -print0)

  if command -v strip >/dev/null 2>&1; then
    find "${DIST}/bin" "${DIST}/lib" -maxdepth 1 -type f -print0 |
      while IFS= read -r -d '' f; do strip --strip-unneeded "${f}" 2>/dev/null || true; done
  fi

  {
    echo "Linux ELF dependencies after bundling"
    echo
    while IFS= read -r -d '' file; do
      echo "[${file#${DIST}/}]"
      LD_LIBRARY_PATH="${DIST}/lib" ldd "${file}" 2>/dev/null | sed 's/^/  /' || true
      echo
    done < <(find "${DIST}/bin" "${DIST}/lib" -maxdepth 1 -type f -print0 | sort -z)
  } > "${DIST}/DEPENDENCIES.txt"
}

is_macos_system_path() {
  local path="$1"
  [[ "${path}" == /System/Library/* || "${path}" == /usr/lib/* ]]
}

resolve_macos_dep() {
  local dep="$1"
  local name="$(basename "${dep}")"

  if [[ "${dep}" == /* && -e "${dep}" ]]; then
    printf '%s\n' "${dep}"
    return 0
  fi

  local candidates=(
    "${PREFIX}/lib/${name}"
    "${DEPS}/lib/${name}"
  )
  if command -v brew >/dev/null 2>&1; then
    local brew_prefix
    brew_prefix="$(brew --prefix)"
    candidates+=("${brew_prefix}/lib/${name}")
  fi

  local c
  for c in "${candidates[@]}"; do
    if [[ -e "${c}" ]]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done

  if command -v brew >/dev/null 2>&1; then
    local found
    found="$(find "$(brew --prefix)/opt" -type f -name "${name}" -print -quit 2>/dev/null || true)"
    if [[ -n "${found}" ]]; then
      printf '%s\n' "${found}"
      return 0
    fi
  fi

  return 1
}

macos_deps() {
  local file="$1"
  otool -L "${file}" 2>/dev/null | tail -n +2 | awk '{print $1}'
}

add_rpath_if_missing() {
  local file="$1" rpath="$2"
  if ! otool -l "${file}" 2>/dev/null | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -Fxq "${rpath}"; then
    install_name_tool -add_rpath "${rpath}" "${file}" 2>/dev/null || true
  fi
}

bundle_macos() {
  command -v otool >/dev/null 2>&1 || { echo "otool is required" >&2; exit 1; }
  command -v install_name_tool >/dev/null 2>&1 || { echo "install_name_tool is required" >&2; exit 1; }

  mkdir -p "${DIST}/lib"
  copy_glob "${DIST}/bin" "${PREFIX}/bin/ffmpeg" "${PREFIX}/bin/ffprobe"
  copy_glob "${DIST}/lib" \
    "${PREFIX}/lib/libmpv*.dylib" \
    "${PREFIX}/lib/libavcodec*.dylib" \
    "${PREFIX}/lib/libavformat*.dylib" \
    "${PREFIX}/lib/libavfilter*.dylib" \
    "${PREFIX}/lib/libavutil*.dylib" \
    "${PREFIX}/lib/libswscale*.dylib" \
    "${PREFIX}/lib/libswresample*.dylib"

  [[ -f "${DIST}/bin/ffmpeg" ]] || { echo "ffmpeg was not installed" >&2; exit 1; }
  compgen -G "${DIST}/lib/libmpv*.dylib" >/dev/null || { echo "libmpv dylib was not installed" >&2; exit 1; }

  local changed=1 file dep resolved name
  while [[ "${changed}" -eq 1 ]]; do
    changed=0
    while IFS= read -r -d '' file; do
      while IFS= read -r dep; do
        [[ -n "${dep}" ]] || continue
        if is_macos_system_path "${dep}"; then
          continue
        fi
        name="$(basename "${dep}")"
        if [[ -e "${DIST}/lib/${name}" ]]; then
          continue
        fi
        resolved="$(resolve_macos_dep "${dep}" || true)"
        if [[ -n "${resolved}" ]]; then
          cp -L "${resolved}" "${DIST}/lib/${name}"
          echo "Bundled macOS dependency: ${name}"
          changed=1
        else
          echo "macOS dependency could not be resolved: ${dep} (from ${file})" >&2
        fi
      done < <(macos_deps "${file}")
    done < <(find "${DIST}/bin" "${DIST}/lib" -maxdepth 1 -type f -print0)
  done

  while IFS= read -r -d '' lib; do
    install_name_tool -id "@rpath/$(basename "${lib}")" "${lib}" 2>/dev/null || true
  done < <(find "${DIST}/lib" -maxdepth 1 -type f -name '*.dylib' -print0)

  while IFS= read -r -d '' file; do
    while IFS= read -r dep; do
      [[ -n "${dep}" ]] || continue
      name="$(basename "${dep}")"
      if [[ -e "${DIST}/lib/${name}" && "${dep}" != "@rpath/${name}" ]]; then
        install_name_tool -change "${dep}" "@rpath/${name}" "${file}" 2>/dev/null || true
      fi
    done < <(macos_deps "${file}")
  done < <(find "${DIST}/bin" "${DIST}/lib" -maxdepth 1 -type f -print0)

  while IFS= read -r -d '' f; do add_rpath_if_missing "${f}" '@loader_path/../lib'; done < <(find "${DIST}/bin" -maxdepth 1 -type f -print0)
  while IFS= read -r -d '' f; do add_rpath_if_missing "${f}" '@loader_path'; done < <(find "${DIST}/lib" -maxdepth 1 -type f -print0)

  if command -v strip >/dev/null 2>&1; then
    find "${DIST}/bin" "${DIST}/lib" -maxdepth 1 -type f -print0 |
      while IFS= read -r -d '' f; do strip -x "${f}" 2>/dev/null || true; done
  fi

  {
    echo "macOS Mach-O dependencies after bundling"
    echo
    while IFS= read -r -d '' file; do
      echo "[${file#${DIST}/}]"
      otool -L "${file}" 2>/dev/null | sed 's/^/  /' || true
      echo
    done < <(find "${DIST}/bin" "${DIST}/lib" -maxdepth 1 -type f -print0 | sort -z)
  } > "${DIST}/DEPENDENCIES.txt"
}

case "${TARGET}" in
  windows-*) bundle_windows ;;
  macos-*) bundle_macos ;;
  linux-*) bundle_linux ;;
  *) echo "unsupported target: ${TARGET}" >&2; exit 2 ;;
esac

echo "Portable runtime staged at: ${DIST}"
