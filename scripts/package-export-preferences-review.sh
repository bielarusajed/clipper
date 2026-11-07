#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The release recipe checks for a clean tree and includes matching dependency
# archives, configuration receipts and the exact committed application sources.
bash scripts/package-release.sh
STAGING="$PWD/.build/export-preferences-review-$(uuidgen)"
APP="$STAGING/Clipper Export Preferences.app"
mkdir -p "$STAGING"
mv dist/Clipper.app "$APP"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Clipper Export Preferences' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Clipper Export Preferences' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.clipper.video.review.export-preferences' "$PLIST"
# This review app should not appear as a Finder video handler.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleDocumentTypes' "$PLIST"
/usr/libexec/PlistBuddy -c 'Delete :UTImportedTypeDeclarations' "$PLIST"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# A receipt outside the git archive records the reviewed commit and packaging
# operation. The script itself is included in that archive for reproducibility.
git rev-parse HEAD > dist/Clipper-Sources/REVIEW-COMMIT.txt
cp scripts/package-export-preferences-review.sh dist/Clipper-Sources/Recipes/
ditto -c -k --keepParent dist/Clipper-Sources dist/Clipper-Export-Preferences-Sources.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Clipper-Export-Preferences-macOS-arm64.zip
if [[ -d "dist/Clipper Export Preferences.app" ]]; then
  mv "dist/Clipper Export Preferences.app" ".build/previous-export-preferences-review-$(uuidgen).app"
fi
mv "$APP" "dist/Clipper Export Preferences.app"
# Keep stable-named intermediates out of the review output directory.
mv dist/Clipper-macOS-arm64.zip dist/Clipper-Sources.zip "$STAGING/"
echo "$PWD/dist/Clipper-Export-Preferences-macOS-arm64.zip"
echo "$PWD/dist/Clipper-Export-Preferences-Sources.zip"
