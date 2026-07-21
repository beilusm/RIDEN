#!/usr/bin/env bash
# build_release.sh — Phase 3 总入口：本地一条命令生成发布版
#
# 执行顺序：
#   1. fetch_tools     — 确保 packaging/tools/runtime-x86_64 存在 + appimagetool 在 PATH
#   2. flutter build  — 生成 build/linux/x64/release/bundle/（AOT + plugins）
#   3. make_appimage   — 手工组装 AppDir + appimagetool 打包成 .AppImage
#   4. compute_checksums — 生成 SHA256SUMS + RELEASE_NOTES-1.0.0.md
#
# 最终产物在 release/：
#   RIDEN_PowerSupply-1.0.0-x86_64.AppImage
#   SHA256SUMS
#   RELEASE_NOTES-1.0.0.md
#
# 用法：
#   ./packaging/scripts/build_release.sh           # 标准发布
#   ./packaging/scripts/build_release.sh --skip-build  # 跳过 flutter build（调试用）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/env.sh
source "${SCRIPT_DIR}/../config/env.sh"

log()  { echo "[build_release] $*"; }
die()  { echo "[build_release][FAIL] $*" >&2; exit 1; }

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

# ── Step 1: fetch tools ────────────────────────────────────────────────────
step_fetch_tools() {
  log "step 1/4: fetch_tools.sh"
  bash "${SCRIPT_DIR}/fetch_tools.sh"
}

# ── Step 2: flutter build linux --release ──────────────────────────────────
step_flutter_build() {
  if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    log "step 2/4: flutter build — SKIPPED (--skip-build)"
    return 0
  fi
  log "step 2/4: flutter build linux --release"

  command -v fvm >/dev/null 2>&1 && FLUTTER="fvm flutter" || FLUTTER="flutter"
  log "  using: ${FLUTTER}"

  # flutter build 失败会直接被 set -e 抓到退出
  ${FLUTTER} build linux --release

  [[ -x "${FLUTTER_BUNDLE_DIR}/riden_power_supply" ]] \
    || die "flutter build 完成但 bundle 里找不到 riden_power_supply"
}

# ── Step 3: make AppImage ──────────────────────────────────────────────────
step_make_appimage() {
  log "step 3/4: make_appimage.sh"
  bash "${SCRIPT_DIR}/make_appimage.sh"
}

# ── Step 4: compute checksums + release notes ──────────────────────────────
step_compute_checksums() {
  log "step 4/4: compute_checksums.sh"
  bash "${SCRIPT_DIR}/compute_checksums.sh"
}

# ── summary ────────────────────────────────────────────────────────────────
summary() {
  log "========================================================"
  log "Release ${APP_VERSION} artifacts in ${RELEASE_DIR}/"
  log "========================================================"
  ls -lh \
    "${RELEASE_DIR}/${APPIMAGE_FILENAME}" \
    "${RELEASE_DIR}/${SHA256SUMS_FILENAME}" \
    "${RELEASE_DIR}/${RELEASE_NOTES_FILENAME}" \
    | sed 's/^/  /'
  log "done."
}

main() {
  log "build_release.sh — RIDEN PowerSupply v${APP_VERSION}"
  log "repo root: ${REPO_ROOT}"
  log "release dir: ${RELEASE_DIR}"
  log ""

  step_fetch_tools
  step_flutter_build
  step_make_appimage
  step_compute_checksums
  summary
}

main "$@"
