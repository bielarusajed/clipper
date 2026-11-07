#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
if ! bash scripts/check-media.sh; then bash scripts/build-media.sh; fi
SWIFT_BUILD=(xcrun swift build --disable-sandbox --scratch-path .build/swift --cache-path .build/cache -c release -debug-info-format none)
"${SWIFT_BUILD[@]}"
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
if [[ ! -f .build/Clipper.icns || scripts/make-icon.swift -nt .build/Clipper.icns ]]; then
  xcrun swift scripts/make-icon.swift
  iconutil -c icns .build/Clipper.iconset -o .build/Clipper.icns
fi
STAGING="$ROOT/.build/package-$(uuidgen)"
APP="$STAGING/Clipper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/Clipper" "$APP/Contents/MacOS/Clipper"
cp .build/media/bin/ffmpeg "$APP/Contents/Helpers/ffmpeg"
cp .build/media/bin/ffprobe "$APP/Contents/Helpers/ffprobe"
python3 scripts/package-libraries.py "$APP"
cp assets/Info.plist "$APP/Contents/Info.plist"
# Review identity is applied only to the staged bundle.
if [[ "${CLIPPER_REVIEW_BUILD:-0}" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Clipper Subtitles' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Clipper Subtitles' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.clipper.review.hardsubs' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleDocumentTypes' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Delete :UTImportedTypeDeclarations' "$APP/Contents/Info.plist"
fi
cp .build/vendor/ffmpeg-8.0.1/COPYING.LGPLv2.1 "$APP/Contents/Resources/Licenses/FFmpeg-LGPL.txt"
cp .build/media-configure.log "$APP/Contents/Resources/Licenses/FFmpeg-build.txt"
cp docs/third-party-notices.txt "$APP/Contents/Resources/Licenses/Notices.txt"
cp .build/vendor/dav1d-1.5.4/COPYING "$APP/Contents/Resources/Licenses/dav1d-BSD.txt"
cp .build/vendor/zimg-release-3.0.6/COPYING "$APP/Contents/Resources/Licenses/zimg-WTFPL.txt"
cp .build/vendor/libass-0.17.3/COPYING "$APP/Contents/Resources/Licenses/libass-ISC.txt"
cp .build/vendor/freetype-2.13.3/docs/FTL.TXT "$APP/Contents/Resources/Licenses/FreeType-FTL.txt"
cp .build/vendor/harfbuzz-10.4.0/COPYING "$APP/Contents/Resources/Licenses/HarfBuzz-MIT.txt"
cp .build/vendor/fribidi-1.0.16/COPYING "$APP/Contents/Resources/Licenses/FriBidi-LGPL.txt"
if [[ -f .build/Clipper.icns ]]; then cp .build/Clipper.icns "$APP/Contents/Resources/Clipper.icns"; fi
find "$APP/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP/Contents/Helpers/ffmpeg"
codesign --force --sign - "$APP/Contents/Helpers/ffprobe"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
NAME=Clipper
if [[ "${CLIPPER_REVIEW_BUILD:-0}" == 1 ]]; then NAME="Clipper Subtitles"; fi
mkdir -p "$ROOT/dist"
if [[ -d "$ROOT/dist/$NAME.app" ]]; then
  mv "$ROOT/dist/$NAME.app" "$ROOT/.build/previous-app-$(uuidgen).app"
fi
mv "$APP" "$ROOT/dist/$NAME.app"
rmdir "$STAGING"
echo "$ROOT/dist/$NAME.app"
