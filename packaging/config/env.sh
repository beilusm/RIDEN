#!/usr/bin/env bash
# Phase 3 packaging configuration — single source of truth.
# Sourced by every packaging script. Keep this file simple: variables only,
# no side-effects, no network access.

# ── Application identity (mirrors Phase 2.1) ────────────────────────────────
export APP_ID="io.github.beilusm.ridenps"
# 文件名用下划线；.desktop 里的 Name= 还是 "RIDEN Power Supply"（Phase 2.3 已设）。
# 不要在 APP_NAME 里用空格 — appimagetool 对输出路径里的空格敏感，会引发误导性
# "Failed to download runtime file" 错误。
export APP_NAME="RIDEN_PowerSupply"
export APP_DISPLAY_NAME="RIDEN Power Supply"
export APP_VERSION="1.0.1"
# 注意：Flutter build 目录用 x64，AppImage 工具链用 x86_64，两个值不同。
export APP_ARCH="x86_64"           # AppImage / appimagetool 命名用
export FLUTTER_ARCH="x64"          # Flutter build/linux/$ARCH/release 用

# ── Output naming ────────────────────────────────────────────────────────────
# 注意：APP_NAME 用下划线分隔，不要用空格 — appimagetool 对输出路径里的空格
# 敏感（在某些环境下 stage 5 失败时给出 "Failed to download runtime file"
# 这种误导性错误）。Display Name 在 .desktop 里用 "RIDEN Power Supply"。
export APPIMAGE_FILENAME="${APP_NAME}-${APP_VERSION}-${APP_ARCH}.AppImage"
export SHA256SUMS_FILENAME="SHA256SUMS"
export RELEASE_NOTES_FILENAME="RELEASE_NOTES-${APP_VERSION}.md"

# ── Tool / runtime strategy ─────────────────────────────────────────────────
# appimagetool：使用系统已装的（Arch: appimagetool-bin 包；Ubuntu: appimagetool）。
#   preflight 里会 `command -v appimagetool` 检查；不存在就报错让用户安装。
#
# linuxdeploy / linuxdeploy-plugin-gtk：**不使用**。
#   plugin-gtk 的 AppRun hook 强制 export GDK_BACKEND=x11 和 GTK_THEME，
#   会破坏用户系统的 HiDPI 主题 / font-scaling-factor 设置。
#   手工方案改为让 AppImage 依赖系统 GTK3（所有 Linux 桌面发行版自带），
#   等价于 `flutter build linux --release` 裸 bundle 的依赖模式。
#
# type2-runtime：appimagetool 需要把 runtime-prepend 到 squashfs 作为 ELF
#   loader。appimagetool 内置下载在某些网络环境下会给出误导性
#   "Failed to download runtime file" 错误，故用 --runtime-file 显式指定。
export APPIMAGE_RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64"

# ── Filesystem layout (all paths resolved at source time) ───────────────────
export PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$(cd "${PACKAGING_DIR}/.." && pwd)"
export TOOLS_DIR="${PACKAGING_DIR}/tools"
export LINUX_DIR="${REPO_ROOT}/linux"

# Build outputs (all gitignored — these are temporary build artifacts)
export BUILD_DIR="${REPO_ROOT}/build"
export FLUTTER_BUNDLE_DIR="${BUILD_DIR}/linux/${FLUTTER_ARCH}/release/bundle"

# release/ layout: AppDir is intermediate, the rest are final deliverables
#   release/AppDir                                   (intermediate, gitignored)
#   release/RIDEN_PowerSupply-1.0.0-x86_64.AppImage  (final, gitignored)
#   release/SHA256SUMS                               (final, gitignored)
#   release/RELEASE_NOTES-1.0.0.md                   (final, gitignored)
export RELEASE_DIR="${REPO_ROOT}/release"
export APPDIR_WORK="${RELEASE_DIR}/AppDir"
