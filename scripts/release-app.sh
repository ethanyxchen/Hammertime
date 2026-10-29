#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NOTARY_KEY_PATH:?Set NOTARY_KEY_PATH to an App Store Connect API key (.p8).}"
: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID to the API key ID.}"
: "${NOTARY_ISSUER_ID:?Set NOTARY_ISSUER_ID to the API key issuer ID.}"
: "${SPARKLE_PRIVATE_KEY_PATH:?Set SPARKLE_PRIVATE_KEY_PATH to the Sparkle EdDSA private key file.}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application}" ./scripts/build-app.sh
app="build/Hammertime.app"
version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
archive="build/Hammertime-$version.zip"
rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --wait \
  --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"
rm "$archive"
ditto -c -k --keepParent "$app" "$archive"
appcast_directory="build/appcast"
rm -rf "$appcast_directory"
mkdir -p "$appcast_directory"
cp "$archive" "$appcast_directory/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
  --download-url-prefix "https://github.com/ethanyxchen/Hammertime/releases/download/v$version/" \
  --link "https://github.com/ethanyxchen/Hammertime" \
  -o build/appcast.xml "$appcast_directory"
