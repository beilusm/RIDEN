#!/usr/bin/env bash
# build_windows_release.sh — Windows Release 总入口（仅 2 步）
#
# 执行顺序：
#   1. fvm flutter build windows --release   (生 build/windows/x64/runner/Release/)
#   2. make_windows_zip.sh                   (打包成 ZIP + 生成 SHA256SUMS)
#
# 不做：fetch_tools（Linux 才需要）/ Inno Setup / NSIS / MSIX / 代码签名
#
# 用法（在 Windows 主机的 Git Bash / WSL 中执行）：
#   bash packaging/scripts/build_windows_release.sh
#   bash packaging/scripts/build_windows_release.sh --skip-build   # 跳过 flutter build，仅打 ZIP（调试）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/env_windows.sh
source "${SCRIPT_DIR}/../config/env_windows.sh"

log()  { echo "[build_windows_release] $*"; }
die()  { echo "[build_windows_release][FAIL] $*" >&2; exit 1; }

SKIP_BUILD=0
for arg in "$@"; do
  case "${arg}" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown arg: ${arg}" ;;
  esac
done

# ── Step 1: flutter build windows --release ────────────────────────────────
step_flutter_build() {
  if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    log "step 1/2: flutter build windows --release — SKIPPED (--skip-build)"
    return 0
  fi
  log "step 1/2: flutter build windows --release"

  command -v fvm >/dev/null 2>&1 && FLUTTER="fvm flutter" || FLUTTER="flutter"
  log "  using: ${FLUTTER}"

  ${FLUTTER} build windows --release

  [[ -x "${WIN_BUNDLE_DIR}/riden_power_supply.exe" ]] \
    || die "flutter build 完成但 bundle 里找不到 riden_power_supply.exe — 检查 Windows SDK / MSVC 安装"
}

# ── Step 2: make ZIP ────────────────────────────────────────────────────────
step_make_zip() {
  log "step 2/2: make_windows_zip.sh"
  bash "${SCRIPT_DIR}/make_windows_zip.sh"
}

# ── summary ────────────────────────────────────────────────────────────────
summary() {
  log "========================================================"
  log "Windows release ${APP_VERSION} artifacts in ${RELEASE_DIR}/"
  log "========================================================"
  ls -lh \
    "${RELEASE_DIR}/${ZIP_FILENAME}" \
    "${RELEASE_DIR}/${SHA256SUMS_FILENAME}" \
    | sed 's/^/  /'
  log ""
  log "下一步：在干净 Windows 10/11 环境解压 ZIP 验证 exe 可独立运行"
  log "done."
}

main() {
  log "build_windows_release.sh — RIDEN PowerSupply v${APP_VERSION} (Windows)"
  log "repo root: ${REPO_ROOT}"
  log "bundle: ${WIN_BUNDLE_DIR}"
  log "release dir: ${RELEASE_DIR}"
  log ""

  step_flutter_build
  step_make_zip
  summary
}

main "$@"
