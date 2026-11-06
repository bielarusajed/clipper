#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache"
if [[ ! -x .build/media/bin/ffmpeg ]]; then bash scripts/build-media.sh; fi
xcrun swift build --build-system native --disable-sandbox --scratch-path .build/swift --cache-path .build/cache -c release -debug-info-format none
xcrun swift scripts/make-icon.swift
iconutil -c icns .build/Clipper.iconset -o .build/Clipper.icns
APP="$ROOT/dist/Clipper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp .build/swift/release/Clipper "$APP/Contents/MacOS/Clipper"
cp .build/media/bin/ffmpeg "$APP/Contents/Helpers/ffmpeg"
cp .build/media/bin/ffprobe "$APP/Contents/Helpers/ffprobe"
python3 scripts/package-libraries.py "$APP"
cp assets/Info.plist "$APP/Contents/Info.plist"
cp .build/vendor/ffmpeg-8.0.1/COPYING.LGPLv2.1 "$APP/Contents/Resources/Licenses/FFmpeg-LGPL.txt"
cp .build/media-configure.log "$APP/Contents/Resources/Licenses/FFmpeg-build.txt"
cp docs/third-party-notices.txt "$APP/Contents/Resources/Licenses/Notices.txt"
cp .build/vendor/dav1d-1.5.4/COPYING "$APP/Contents/Resources/Licenses/dav1d-BSD.txt"
cp .build/vendor/zimg-release-3.0.6/COPYING "$APP/Contents/Resources/Licenses/zimg-WTFPL.txt"
if [[ -f .build/Clipper.icns ]]; then cp .build/Clipper.icns "$APP/Contents/Resources/Clipper.icns"; fi
find "$APP/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP/Contents/Helpers/ffmpeg"
codesign --force --sign - "$APP/Contents/Helpers/ffprobe"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
