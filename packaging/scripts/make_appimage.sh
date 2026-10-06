#!/usr/bin/env bash
set -euo pipefail

# Package the Compose application image, including its jlink runtime.
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_dir"
version="$(tr -d '\r\n' < VERSION)"
[[ "$version" =~ ^[1-9][0-9]*\.[0-9]+\.[0-9]+(-[1-9][0-9]*)?$ ]] || { echo "Invalid VERSION" >&2; exit 1; }
./gradlew :composeApp:createDistributable
command -v appimagetool >/dev/null || { echo "Install appimagetool first" >&2; exit 1; }
mkdir -p "$project_dir/composeApp/build/appimage"
staging_dir="$(mktemp -d "$project_dir/composeApp/build/appimage/staging.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/RIDEN.AppDir"
mkdir -p "$app_dir/usr/lib" "$project_dir/release"
cp -a composeApp/build/compose/binaries/main/app/RIDEN "$app_dir/usr/lib/"
cp packaging/appimage/AppRun "$app_dir/AppRun"
chmod +x "$app_dir/AppRun"
cp packaging/appimage/io.github.beilusm.ridenps.desktop "$app_dir/"
cp linux/icons/hicolor/512x512/apps/io.github.beilusm.ridenps.png "$app_dir/"
cp linux/icons/hicolor/512x512/apps/io.github.beilusm.ridenps.png "$app_dir/.DirIcon"
artifact="RIDEN-$version-x86_64.AppImage"
ARCH=x86_64 appimagetool "$app_dir" "$staging_dir/$artifact"
mv -f "$staging_dir/$artifact" "$project_dir/release/$artifact"
(cd release && sha256sum "$artifact" > SHA256SUMS-linux.txt)
