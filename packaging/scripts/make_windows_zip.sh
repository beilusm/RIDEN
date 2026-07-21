#!/usr/bin/env bash
# make_windows_zip.sh — 把 build/windows/x64/runner/Release/ 打包成分发用 ZIP
#
# 设计：
#   - 仅打包 Release/ 目录内容，ZIP 顶层目录名 RIDEN_PowerSupply/
#     解压后用户得到一个独立文件夹 RIDEN_PowerSupply/，双击 .exe 即可运行
#   - 不打安装器，不做代码签名，不嵌入 Flutter SDK
#   - 在 ZIP 内同时写入 MANIFEST.txt（文件清单 + SHA256）
#   - Python zipfile 是唯一打包工具（Flutter on Windows 必装 Python 3，无需额外依赖）
#
# 用法（在 Windows/WSL/Git Bash 中）：
#   先执行：fvm flutter build windows --release
#   再执行：bash packaging/scripts/make_windows_zip.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/env_windows.sh
source "${SCRIPT_DIR}/../config/env_windows.sh"

log()  { echo "[make_windows_zip] $*"; }
die()  { echo "[make_windows_zip][FAIL] $*" >&2; exit 1; }

# ── Preflight ──────────────────────────────────────────────────────────────
preflight() {
  log "preflight: checking ${WIN_BUNDLE_DIR}"
  [[ -d "${WIN_BUNDLE_DIR}" ]] \
    || die "Release bundle 不存在：${WIN_BUNDLE_DIR}
请先在 Windows 主机执行：fvm flutter build windows --release"

  local required=(
    "${WIN_BUNDLE_DIR}/riden_power_supply.exe"
    "${WIN_BUNDLE_DIR}/flutter_windows.dll"
    "${WIN_BUNDLE_DIR}/data/icudtl.dat"
    "${WIN_BUNDLE_DIR}/data/app.so"
    "${WIN_BUNDLE_DIR}/data/flutter_assets/AssetManifest.json"
  )
  for f in "${required[@]}"; do
    [[ -f "$f" ]] || die "缺少必备文件: $f"
  done
  log "preflight: OK (5 必备文件齐全)"
}

# ── ZIP 打包 + MANIFEST 生成（用 Python 一站式完成）──────────────────────
make_zip() {
  [[ -x "$(command -v python3)" ]] || die "找不到 python3（Flutter on Windows 必装）"
  local zip_path="${RELEASE_DIR}/${ZIP_FILENAME}"
  mkdir -p "${RELEASE_DIR}"
  rm -f "${zip_path}" "${RELEASE_DIR}/${SHA256SUMS_FILENAME}"

  log "creating ZIP: ${zip_path}"
  python3 - <<PYEOF
import os, zipfile, hashlib, datetime, sys

bundle = "${WIN_BUNDLE_DIR}"
zip_path = "${zip_path}"
top = "${APP_NAME}"
version = "${APP_VERSION}"

# Step 1: 收集所有文件 + 计算每个文件的 SHA256
entries = []
for root, dirs, files in os.walk(bundle):
    for fn in sorted(files):
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, bundle).replace(os.sep, '/')
        with open(full, 'rb') as f:
            sha = hashlib.sha256(f.read()).hexdigest()
        size = os.path.getsize(full)
        entries.append((rel, size, sha, full))

# Step 2: 生成 MANIFEST 内容
manifest_lines = [
    "RIDEN Power Supply — Windows Release Manifest",
    f"Version: {version}",
    f"Generated: {datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
    f"Files: {len(entries)}",
    "",
    "Content (relative path inside RIDEN_PowerSupply/):",
    "",
    f"{'PATH':<60} {'SIZE':>12}  SHA256",
    "-" * 120,
]
for rel, size, sha, _ in entries:
    manifest_lines.append(f"{rel:<60} {size:>12}  {sha}")
manifest_content = "\n".join(manifest_lines) + "\n"

# Step 3: 写 ZIP
total = 0
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    # 先写 MANIFEST.txt 到顶层
    zf.writestr(f"{top}/MANIFEST.txt", manifest_content)
    total += 1
    # 再写所有 bundle 文件
    for rel, size, sha, full in entries:
        arc = f"{top}/{rel}"
        zf.write(full, arc)
        total += 1

final_size = os.path.getsize(zip_path)
print(f"[make_windows_zip] ZIP created: {zip_path}")
print(f"[make_windows_zip]   entries: {total} (含 MANIFEST.txt)")
print(f"[make_windows_zip]   size:    {final_size} bytes ({final_size/1024/1024:.2f} MB)")
PYEOF

  [[ -f "${zip_path}" ]] || die "ZIP 生成失败"
}

# ── SHA256SUMS-windows.txt ──────────────────────────────────────────────────
compute_sha256() {
  local sha_path="${RELEASE_DIR}/${SHA256SUMS_FILENAME}"
  local zip_path="${RELEASE_DIR}/${ZIP_FILENAME}"
  log "computing SHA256 for ${ZIP_FILENAME}"
  (cd "${RELEASE_DIR}" && sha256sum "${ZIP_FILENAME}" > "${sha_path}")
  log "  $(cat "${sha_path}")"
}

# ── summary ──────────────────────────────────────────────────────────────────
summary() {
  log "========================================================"
  log "Windows release ${APP_VERSION} artifacts in ${RELEASE_DIR}/"
  log "========================================================"
  ls -lh "${RELEASE_DIR}/${ZIP_FILENAME}" \
         "${RELEASE_DIR}/${SHA256SUMS_FILENAME}" \
    | sed 's/^/  /'
  log ""
  log "验证：sha256sum -c ${SHA256SUMS_FILENAME}"
  log "done."
}

main() {
  log "make_windows_zip.sh — RIDEN PowerSupply v${APP_VERSION} (Windows)"
  log "bundle: ${WIN_BUNDLE_DIR}"
  log "release dir: ${RELEASE_DIR}"
  log ""

  preflight
  make_zip
  compute_sha256
  summary
}

main "$@"
