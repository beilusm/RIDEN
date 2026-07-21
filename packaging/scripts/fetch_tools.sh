#!/usr/bin/env bash
# fetch_tools.sh — 下载 type2-runtime 到 packaging/tools/
#
# AppImage 工具链策略：
#   - appimagetool：使用系统已装的（Arch: appimagetool-bin；Ubuntu/Debian: appimagetool 包）
#   - linuxdeploy / linuxdeploy-plugin-gtk：不使用（HiDPI 兼容性问题，见 env.sh）
#   - type2-runtime：从这里下载，作为 --runtime-file 参数传给 appimagetool
#
# Idempotent：runtime-x86_64 已存在则跳过下载。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/env.sh
source "${SCRIPT_DIR}/../config/env.sh"

log() { echo "[fetch_tools] $*"; }
die() { echo "[fetch_tools][FAIL] $*" >&2; exit 1; }

# 用 POSIX od 读取前 4 字节判断 ELF，避免对 file 命令的依赖。
verify_elf() {
  local f="$1"
  local magic
  magic="$(od -An -tx1 -N4 <"$f" 2>/dev/null | tr -d ' \n')"
  [[ "${magic}" == "7f454c46"* ]] || return 1
}

main() {
  log "preflight: appimagetool on PATH"
  command -v appimagetool >/dev/null \
    || die "appimagetool 未安装：Arch 用 'pacman -S appimagetool-bin'，Ubuntu/Debian 用 'apt install appimagetool'"

  log "TOOLS_DIR=${TOOLS_DIR}"
  mkdir -p "${TOOLS_DIR}"

  local dest="${TOOLS_DIR}/runtime-x86_64"
  if [[ -x "${dest}" ]]; then
    log "runtime-x86_64: already present, skip"
  else
    log "runtime-x86_64: downloading from ${APPIMAGE_RUNTIME_URL}"
    curl -L --fail --silent --show-error -o "${dest}.tmp" "${APPIMAGE_RUNTIME_URL}"
    chmod +x "${dest}.tmp"
    if ! verify_elf "${dest}.tmp"; then
      rm -f "${dest}.tmp"
      die "downloaded file is not a valid ELF — check URL or network"
    fi
    mv "${dest}.tmp" "${dest}"
    log "runtime-x86_64: saved → ${dest}"
    log "runtime-x86_64: sha256=$(sha256sum "${dest}" | awk '{print $1}')"
  fi

  log "summary:"
  ls -lh "${TOOLS_DIR}"
}

main "$@"
