#!/usr/bin/env bash
# Windows release packaging configuration — single source of truth.
# Sourced by every Windows packaging script. Variables only, no side-effects.
#
# 与 env.sh (Linux) 对照：
#   - APP_ID / APP_VERSION / APP_NAME / APP_DISPLAY_NAME 保持 4 处一致铁律
#     (linux/CMakeLists.txt:10 / windows/runner/Runner.rc / pubspec.yaml version / env*.sh APP_ID-VERSION)
#   - Windows 不引入安装器（Inno Setup / NSIS / MSIX 全部延期）
#   - 仅产出可分发的 ZIP 包

# ── Application identity (与 Linux env.sh 同步) ─────────────────────────────
export APP_ID="io.github.beilusm.ridenps"
export APP_NAME="RIDEN_PowerSupply"          # 文件名用下划线，避免空格敏感工具
export APP_DISPLAY_NAME="RIDEN Power Supply" # UI 显示名 / 资源 ProductName
export APP_VERSION="1.0.4"
# Windows Flutter build 路径用 x64（与 Linux 一致），不区分 x86_64 / x64
export FLUTTER_ARCH="x64"
export WIN_ARCH_LABEL="x64"                   # ZIP 命名用

# ── Output naming ────────────────────────────────────────────────────────────
# 最终交付物：单个 ZIP（含完整 build/windows/x64/runner/Release/ 目录） + SHARED Release Notes
export ZIP_FILENAME="${APP_NAME}-${APP_VERSION}-windows-${WIN_ARCH_LABEL}.zip"
export SHA256SUMS_FILENAME="SHA256SUMS-windows.txt"
# Release Notes 跨平台共享 metainfo 抽取结果，由 Linux compute_checksums.sh 生成
# Windows 端不重复生成，假定 Linux release/ 已有 RELEASE_NOTES-1.0.0.md（或后续单独补）
export RELEASE_NOTES_FILENAME="RELEASE_NOTES-${APP_VERSION}.md"

# ── Filesystem layout ────────────────────────────────────────────────────────
export PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$(cd "${PACKAGING_DIR}/.." && pwd)"

# Flutter build 产物路径（flutter build windows --release 输出）
export BUILD_DIR="${REPO_ROOT}/build"
export WIN_BUNDLE_DIR="${BUILD_DIR}/windows/${FLUTTER_ARCH}/runner/Release"

# release/ layout（与 Linux 共享 release/ 目录）
#   release/${ZIP_FILENAME}             (final, gitignored)
#   release/${SHA256SUMS_FILENAME}      (final, gitignored)
#   release/${RELEASE_NOTES_FILENAME}   (final, gitignored，Linux 已生成)
export RELEASE_DIR="${REPO_ROOT}/release"
