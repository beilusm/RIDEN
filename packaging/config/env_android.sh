#!/usr/bin/env bash
# Phase 4 Android release packaging configuration — single source of truth.
# Sourced by every Android packaging script. Variables only, no side-effects.
#
# 与 env.sh (Linux) / env_windows.sh 对照：
#   - APP_ID / APP_VERSION / APP_NAME / APP_DISPLAY_NAME 保持 4 处一致铁律
#     (linux/CMakeLists.txt:10 / windows/runner/Runner.rc / pubspec.yaml version / env*.sh APP_ID-VERSION)
#   - Android 不引入 Play Store 上架（Phase 4 范围外）
#   - 仅产出可分发的 APK 包

# ── Application identity (与 Linux / Windows env 同步) ─────────────────────
export APP_ID="io.github.beilusm.ridenps"
export APP_NAME="RIDEN_PowerSupply"          # 文件名用下划线，避免空格敏感工具
export APP_DISPLAY_NAME="RIDEN Power Supply" # UI 显示名 / android:label
export APP_VERSION="1.1.1"
# Android Flutter build 路径用 apk / debug | release （不区分 x64/arm64)
export APK_FLAVOR="release"                  # Flutter build apk --release 输出
# ARB / abi splits 默认输出 arm64-v8a + armeabi-v7a + x86_64 — release-android
# workflow 只发布 arm64-v8a 减小体积(主 Android 11 OTG 手机会用)
export APK_ABI="arm64-v8a"                   # APK 命名用

# ── Output naming ────────────────────────────────────────────────────────────
# 最终交付物：单个 APK + SHA256SUMS-android.txt
export APK_FILENAME="${APP_NAME}-${APP_VERSION}-android-${APK_ABI}.apk"
export SHA256SUMS_FILENAME="SHA256SUMS-android.txt"
# Release Notes 跨平台共享 metainfo 抽取结果
export RELEASE_NOTES_FILENAME="RELEASE_NOTES-${APP_VERSION}.md"

# ── Filesystem layout ────────────────────────────────────────────────────────
export PACKAGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT="$(cd "${PACKAGING_DIR}/.." && pwd)"

# Flutter build 产物路径（flutter build apk --release 输出）
export BUILD_DIR="${REPO_ROOT}/build"
export APK_DIR="${BUILD_DIR}/app/outputs/flutter-apk"

# release/ layout（与 Linux / Windows 共享 release/ 目录）
#   release/${APK_FILENAME}              (final, gitignored)
#   release/${SHA256SUMS_FILENAME}        (final, gitignored)
#   release/${RELEASE_NOTES_FILENAME}     (final, gitignored，Linux 已生成)
export RELEASE_DIR="${REPO_ROOT}/release"

# ── Android signing (release-android.yml CI 用) ────────────────────────────
# CI 默认 debug 签名（v1.1.0 alpha 范围）。后续 v1.2.0 引入 keystore：
#   secrets.ANDROID_KEYSTORE_BASE64 -> ~/.keystore/riden.keystore
#   secrets.ANDROID_KEY_ALIAS / *_STORE_PASS / *_KEY_PASS
# 此处仅留变量占位，本地构建不需要。
export ANDROID_KEYSTORE=""
export ANDROID_KEY_ALIAS=""
export ANDROID_STORE_PASS=""
export ANDROID_KEY_PASS=""
