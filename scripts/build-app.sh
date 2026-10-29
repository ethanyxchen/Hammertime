#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
destination="$PWD/build/Hammertime.app"
require_app_stopped() {
  while read -r app_pid; do
    if [[ "$(ps -p "$app_pid" -o comm=)" == "$destination/Contents/MacOS/Hammertime" ]]; then
      printf 'Quit Hammertime before replacing its signed app bundle.\n' >&2
      exit 1
    fi
  done < <(pgrep -x Hammertime || true)
}
require_app_stopped
if grep -l '^version https://git-lfs.github.com/spec/v1' Sources/GitHubMaxxer/Resources/* >/dev/null; then
  printf 'Hammer assets are Git LFS pointers. Run git lfs install && git lfs pull, then build again.\n' >&2
  exit 1
fi
swift build -c release
binary_directory="$(swift build -c release --show-bin-path)"
mkdir -p "$PWD/build"
staging_directory="$(mktemp -d "$PWD/build/.hammertime.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
app_bundle="$staging_directory/Hammertime.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Frameworks"
cp "$binary_directory/Hammertime" "$app_bundle/Contents/MacOS/Hammertime"
ditto "$binary_directory/Sparkle.framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$app_bundle/Contents/MacOS/Hammertime"
cp Resources/Info.plist "$app_bundle/Contents/Info.plist"
tag="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || echo v0.0.0)"
version="${tag#v}"
plutil -insert CFBundleShortVersionString -string "$version" "$app_bundle/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$version" "$app_bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_bundle/Contents/Resources/AppIcon.icns"
cp Sources/GitHubMaxxer/Resources/* "$app_bundle/Contents/Resources/"
plutil -lint "$app_bundle/Contents/Info.plist"
identity="${CODESIGN_IDENTITY:-Apple Development}"
sparkle="$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested in "$sparkle/XPCServices/Installer.xpc" "$sparkle/XPCServices/Downloader.xpc" "$sparkle/Autoupdate" "$sparkle/Updater.app" "$app_bundle/Contents/Frameworks/Sparkle.framework"; do
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$nested"
done
codesign --force --options runtime --timestamp --sign "$identity" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
require_app_stopped
rm -rf "$destination"
mv "$app_bundle" "$destination"
printf 'Built %s\n' "$destination"
