#!/usr/bin/env bash
# make_appimage.sh — 手工组装 AppDir 并用 appimagetool 封装为 AppImage
#
#   Stage 1: 清空并重建 ${RELEASE_DIR}/AppDir
#   Stage 2: 把 Flutter bundle 内容拷到 AppDir/（保留 rpath=$ORIGIN/lib）
#   Stage 3: 拷 .desktop / hicolor icons / AppStream metainfo 到 AppDir/usr/share/
#   Stage 4: 在 AppDir 根写 AppRun、创建 .DirIcon / .desktop / .png 符号链接
#   Stage 5: 调系统 appimagetool + --runtime-file 把 AppDir 打成 .AppImage
#
# 设计原则：AppRun 不设任何 GTK_THEME / GDK_BACKEND / GTK_PATH 等环境变量。
# 这等价于 `flutter build linux --release` 裸 bundle 的运行环境，让用户系统的
# HiDPI 主题 / font-scaling-factor 设置保持原样。代价是要求用户发行版自带
# GTK3（所有 Linux 桌面发行版都自带）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/env.sh
source "${SCRIPT_DIR}/../config/env.sh"

log()  { echo "[make_appimage] $*"; }
die()  { echo "[make_appimage][FAIL] $*" >&2; exit 1; }

# ── pre-flight ─────────────────────────────────────────────────────────────
preflight() {
  log "pre-flight checks"

  log "  appimagetool on PATH"
  command -v appimagetool >/dev/null \
    || die "appimagetool 未安装：Arch 'pacman -S appimagetool-bin'，Ubuntu 'apt install appimagetool'"

  log "  Flutter release bundle"
  [[ -d "${FLUTTER_BUNDLE_DIR}" ]] \
    || die "Flutter release bundle 未找到: ${FLUTTER_BUNDLE_DIR}（先跑 build_release.sh）"
  [[ -x "${FLUTTER_BUNDLE_DIR}/riden_power_supply" ]] \
    || die "bundle 里找不到可执行文件 riden_power_supply"
  [[ -d "${FLUTTER_BUNDLE_DIR}/lib" ]] \
    || die "bundle 里找不到 lib/ 目录"
  [[ -d "${FLUTTER_BUNDLE_DIR}/data" ]] \
    || die "bundle 里找不到 data/ 目录"

  log "  type2-runtime"
  [[ -r "${TOOLS_DIR}/runtime-x86_64" ]] \
    || die "runtime-x86_64 未找到: ${TOOLS_DIR}/runtime-x86_64（先跑 fetch_tools.sh）"

  log "  Linux integration assets"
  [[ -f "${LINUX_DIR}/applications/${APP_ID}.desktop" ]] \
    || die ".desktop 未找到"
  [[ -f "${LINUX_DIR}/icons/hicolor/256x256/apps/${APP_ID}.png" ]] \
    || die "256x256 icon 未找到"
  [[ -f "${LINUX_DIR}/metainfo/${APP_ID}.metainfo.xml" ]] \
    || die "metainfo 未找到"
}

# ── Stage 1: 清空 AppDir ───────────────────────────────────────────────────
prepare_appdir() {
  log "stage 1: 清空 AppDir"
  rm -rf "${APPDIR_WORK}"
  mkdir -p "${APPDIR_WORK}/usr/share/applications" \
           "${APPDIR_WORK}/usr/share/icons/hicolor" \
           "${APPDIR_WORK}/usr/share/metainfo"
}

# ── Stage 2: 拷 Flutter bundle ─────────────────────────────────────────────
copy_bundle() {
  log "stage 2: 拷 Flutter bundle → AppDir/"
  # Flutter bundle 顶层布局直接平铺到 AppDir 根，rpath=$ORIGIN/lib 不变。
  #   AppDir/riden_power_supply      <- Flutter binary
  #   AppDir/lib/                    <- plugin .so + libserialport.so + libflutter_linux_gtk.so
  #   AppDir/data/                   <- flutter_assets + icudtl.dat
  cp -a "${FLUTTER_BUNDLE_DIR}/." "${APPDIR_WORK}/"
}

# ── Stage 3: 拷 Linux 集成资源 ────────────────────────────────────────────
copy_integration_assets() {
  log "stage 3: 拷 .desktop / icons / metainfo → AppDir/usr/share/"
  cp "${LINUX_DIR}/applications/${APP_ID}.desktop" \
     "${APPDIR_WORK}/usr/share/applications/"
  cp -a "${LINUX_DIR}/icons/hicolor/." \
     "${APPDIR_WORK}/usr/share/icons/hicolor/"
  cp "${LINUX_DIR}/metainfo/${APP_ID}.metainfo.xml" \
     "${APPDIR_WORK}/usr/share/metainfo/"

  # 刷新 icon cache（best-effort；失败也不影响打包）
  if command -v gtk-update-icon-cache >/dev/null; then
    gtk-update-icon-cache -f -q "${APPDIR_WORK}/usr/share/icons/hicolor" 2>/dev/null || true
  fi
}

# ── Stage 4: 在 AppDir 根写 AppRun、创建符号链接 ─────────────────────────
# AppImage 规范规定：AppDir 根目录要有
#   - AppRun            可执行入口（可以是 ELF 或脚本）
#   - .DirIcon          给文件管理器用的图标（symlink 到 PNG）
#   - <APP_ID>.desktop  给桌面集成用的 .desktop（symlink 到 usr/share/）
#   - <APP_ID>.png       给某些文件管理器用的 PNG（symlink）
finalize_appdir_root() {
  log "stage 4: 写 AppRun + 根目录符号链接"

  # AppRun：极简 wrapper，不设任何 GTK 环境变量，保持用户系统 HiDPI 设置。
  # 用 readlink -f 解析 AppImage 挂载点路径（AppImage 在 /tmp/mount-xxxx/ 下）。
  cat >"${APPDIR_WORK}/AppRun" <<'APPRUN_EOF'
#!/usr/bin/env bash
# AppRun — AppImage entry point for RIDEN PowerSupply.
# 故意不设 GDK_BACKEND / GTK_THEME / GTK_PATH 等环境变量。
# 让用户系统的 HiDPI 主题与 font-scaling-factor 保持原样。
set -e
this_dir="$(readlink -f "$(dirname "$0")")"
export APPDIR="${APPDIR:-"$this_dir"}"
# 把内置资源目录加到 XDG_DATA_DIRS 前面，方便文件管理器找 .desktop / icons。
export XDG_DATA_DIRS="$this_dir/usr/share:${XDG_DATA_DIRS:-/usr/share}"
exec "$this_dir/riden_power_supply" "$@"
APPRUN_EOF
  chmod 0755 "${APPDIR_WORK}/AppRun"

  # .DirIcon：appimagetool 要求，给文件管理器 thumbnail 用。256x256 是惯例。
  ln -sf "usr/share/icons/hicolor/256x256/apps/${APP_ID}.png" \
         "${APPDIR_WORK}/.DirIcon"

  # <APP_ID>.desktop 与 <APP_ID>.png 放在根目录作为 AppImage 规范要求的入口标识。
  ln -sf "usr/share/applications/${APP_ID}.desktop" \
         "${APPDIR_WORK}/${APP_ID}.desktop"
  ln -sf "usr/share/icons/hicolor/256x256/apps/${APP_ID}.png" \
         "${APPDIR_WORK}/${APP_ID}.png"

  log "AppDir root listing:"
  ls -la "${APPDIR_WORK}" | sed 's/^/    /'
}

# ── Stage 5: appimagetool 打包 ─────────────────────────────────────────────
run_appimagetool() {
  log "stage 5: appimagetool"
  local out="${RELEASE_DIR}/${APPIMAGE_FILENAME}"
  local runtime="${TOOLS_DIR}/runtime-x86_64"
  rm -f "${out}"

  # --runtime-file 显式指定 type2-runtime，避免 appimagetool 内置下载在某些
  # 网络环境下给出误导性 "Failed to download runtime file" 错误。
  # -n 跳过 AppStream 元数据在线校验（GitHub repo 尚未上线，见 SESSION_HANDOFF）。
  appimagetool \
    --runtime-file "${runtime}" \
    -n \
    "${APPDIR_WORK}" \
    "${out}"

  [[ -f "${out}" ]] || die "AppImage 未生成: ${out}"
  chmod +x "${out}"
  log "produced: ${out}"
  ls -lh "${out}"
}

main() {
  preflight
  prepare_appdir
  copy_bundle
  copy_integration_assets
  finalize_appdir_root
  run_appimagetool
  log "done"
}

main "$@"
