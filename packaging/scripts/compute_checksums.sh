#!/usr/bin/env bash
# compute_checksums.sh — 生成发布产物的 SHA256SUMS + Release Notes
#
#   产物 1: ${RELEASE_DIR}/${SHA256SUMS_FILENAME}
#     格式：标准 GNU coreutils `sha256sum` 输出
#       <sha256>  <filename>
#     只列最终交付物（AppImage），不列中间产物（AppDir）。
#
#   产物 2: ${RELEASE_DIR}/${RELEASE_NOTES_FILENAME}
#     Markdown 格式，包含：
#       - 应用名 / 版本 / 日期 / 体积
#       - SHA256 校验和（与 SHA256SUMS 一致，方便用户直接复制）
#       - Release notes（从 linux/metainfo/*.metainfo.xml 抽 <description> 文本）
#       - 系统要求 / 安装步骤 / 已知问题
#
# 本脚本不重新构建 AppImage，只对已存在的产物生成摘要。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/env.sh
source "${SCRIPT_DIR}/../config/env.sh"

log()  { echo "[compute_checksums] $*"; }
die()  { echo "[compute_checksums][FAIL] $*" >&2; exit 1; }

# ── pre-flight ─────────────────────────────────────────────────────────────
preflight() {
  log "pre-flight checks"
  [[ -f "${RELEASE_DIR}/${APPIMAGE_FILENAME}" ]] \
    || die "AppImage 未找到: ${RELEASE_DIR}/${APPIMAGE_FILENAME}（先跑 make_appimage.sh）"
  [[ -f "${LINUX_DIR}/metainfo/${APP_ID}.metainfo.xml" ]] \
    || die "metainfo 未找到"
  command -v xmllint >/dev/null \
    || die "xmllint 未安装：Arch 'pacman -S libxml2'，Ubuntu 'apt install libxml2-utils'"
  command -v sha256sum >/dev/null \
    || die "sha256sum 未安装（GNU coreutils 应自带）"
}

# ── SHA256SUMS ─────────────────────────────────────────────────────────────
generate_sha256sums() {
  log "stage 1: 生成 SHA256SUMS"
  local appimage="${RELEASE_DIR}/${APPIMAGE_FILENAME}"
  local sums="${RELEASE_DIR}/${SHA256SUMS_FILENAME}"

  # 只保留文件名（不包含路径），这样 `sha256sum -c` 可在发布目录直接校验。
  ( cd "${RELEASE_DIR}" && sha256sum "${APPIMAGE_FILENAME}" > "${SHA256SUMS_FILENAME}" )

  log "  → ${sums}"
  sed 's/^/    /' "${sums}"
}

# ── Release Notes ──────────────────────────────────────────────────────────
# 从 metainfo XML 抽 <description> 的内容降级为 Markdown。
# 元信息（version / date / 体积 / sha256）由 generate_release_notes 写在头部，
# 这里只负责 description 主体。
extract_release_notes() {
  local xml="${LINUX_DIR}/metainfo/${APP_ID}.metainfo.xml"

  xmllint --xpath '//releases/release[1]/description' "${xml}" 2>/dev/null \
    | sed -E \
      -e 's|<description>||' -e 's|</description>||' \
      -e 's|<p>|\n|g' -e 's|</p>|\n|g' \
      -e 's|<ul>|\n|g' -e 's|</ul>||g' \
      -e 's|<li>|- |g' -e 's|</li>||g' \
      -e 's|<[^>]+>||g' \
    | awk '{
        # strip leading/trailing whitespace on each line
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+$/, "")
        # collapse blank runs — only print when line is non-empty,
        # and skip if it duplicates the previous blank
        if (length($0) == 0) {
          if (!blank) print ""
          blank = 1
        } else {
          print
          blank = 0
        }
      }'
}

generate_release_notes() {
  log "stage 2: 生成 Release Notes"
  local appimage="${RELEASE_DIR}/${APPIMAGE_FILENAME}"
  local notes="${RELEASE_DIR}/${RELEASE_NOTES_FILENAME}"
  local sha256 size_human build_date

  sha256="$( awk '{print $1}' "${RELEASE_DIR}/${SHA256SUMS_FILENAME}" )"
  size_human="$( du -h "${appimage}" | awk '{print $1}' )"
  build_date="$( date -u +%Y-%m-%d )"

  {
    echo "# ${APP_DISPLAY_NAME} ${APP_VERSION}"
    echo
    echo "- **Version**: ${APP_VERSION}"
    echo "- **Build date**: ${build_date} (UTC)"
    echo "- **Architecture**: ${APP_ARCH}"
    echo "- **AppImage size**: ${size_human}"
    echo "- **App ID**: \`${APP_ID}\`"
    echo
    echo "## SHA256 checksum"
    echo
    echo '```'
    echo "${sha256}  ${APPIMAGE_FILENAME}"
    echo '```'
    echo
    echo "## Release notes"
    echo
    extract_release_notes
    echo
    echo "## System requirements"
    echo
    echo "- Linux x86_64 (glibc ≥ 2.31)"
    echo "- GTK 3 (preinstalled on all desktop distributions)"
    echo "- CH340 / CH341 USB-serial driver (\`ch341\` kernel module)"
    echo "- For serial port access without root: install the udev rule — see README"
    echo
    echo "## Install / Run"
    echo
    echo '```bash'
    echo "chmod +x ${APPIMAGE_FILENAME}"
    echo "./${APPIMAGE_FILENAME}"
    echo '```'
    echo
    echo "## Verify"
    echo
    echo '```bash'
    echo "sha256sum -c ${SHA256SUMS_FILENAME}"
    echo '```'
    echo
    echo "## Known issues"
    echo
    echo "- GitHub repository not yet published — AppStream \`url\` fields are unreachable"
    echo "  (metainfo is validated with \`--no-net\`)"
    echo "- Internal observation OBS-1 / OBS-2 — see \`docs/SESSION_HANDOFF.md\`"
    echo
  } > "${notes}"

  log "  → ${notes}"
  log "  preview（前 25 行）："
  sed -n '1,25p' "${notes}" | sed 's/^/    /'
}

main() {
  preflight
  generate_sha256sums
  generate_release_notes
  log "done"
  log "final deliverables in ${RELEASE_DIR}:"
  ls -lh "${RELEASE_DIR}/${APPIMAGE_FILENAME}" \
        "${RELEASE_DIR}/${SHA256SUMS_FILENAME}" \
        "${RELEASE_DIR}/${RELEASE_NOTES_FILENAME}" \
    | sed 's/^/    /'
}

main "$@"
