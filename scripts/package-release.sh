#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then echo 'Commit the working tree before packaging matching sources.' >&2; exit 1; fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' assets/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' assets/Info.plist)"
APP_ZIP="Clipper-$VERSION-macOS-arm64.zip"
SOURCE_ZIP="Clipper-$VERSION-Sources.zip"
CHECKSUMS="Clipper-$VERSION-SHA256.txt"
bash scripts/build-app.sh
if [[ -d dist/Clipper-Sources ]]; then mv dist/Clipper-Sources ".build/previous-sources-$(uuidgen)"; fi
mkdir -p dist/Clipper-Sources/Dependencies dist/Clipper-Sources/Recipes
cp .build/vendor/ffmpeg-8.0.1.tar.xz .build/vendor/dav1d-1.5.4.tar.gz .build/vendor/zimg-3.0.6.tar.gz dist/Clipper-Sources/Dependencies/
cp .build/media/tls-patch.sha256 patches/ffmpeg-8.0.1-tls-verify-default.patch dist/Clipper-Sources/Dependencies/
cp .build/media/config.mak .build/media-configure.log dist/Clipper-Sources/Recipes/
cp scripts/build-*.sh scripts/build-zimg.py scripts/media-pkg-config.sh dist/Clipper-Sources/Recipes/
cp .build/vendor/{pkgconf-2.3.0,freetype-2.13.3,fribidi-1.0.16,harfbuzz-10.4.0,libass-0.17.3}.tar.xz dist/Clipper-Sources/Dependencies/
cp scripts/subtitle-sources.sha256 dist/Clipper-Sources/Recipes/
git rev-parse HEAD > dist/Clipper-Sources/COMMIT.txt
{
  echo "Clipper $VERSION ($BUILD)"
  echo 'Apple Silicon; macOS 14 or newer; ad-hoc signed'
} > dist/Clipper-Sources/BUILD.txt
git archive HEAD -o dist/Clipper-Sources/Clipper-source.tar
cp docs/third-party-notices.txt dist/Clipper-Sources/
ditto -c -k --sequesterRsrc --keepParent dist/Clipper.app "dist/$APP_ZIP"
ditto -c -k --keepParent dist/Clipper-Sources "dist/$SOURCE_ZIP"
(cd dist; shasum -a 256 "$APP_ZIP" "$SOURCE_ZIP" > "$CHECKSUMS")
echo "Distribute $APP_ZIP and $SOURCE_ZIP together. Checksums: $CHECKSUMS"
