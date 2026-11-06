#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh
mkdir -p dist/Clipper-Sources/Dependencies dist/Clipper-Sources/Recipes
cp .build/vendor/ffmpeg-8.0.1.tar.xz .build/vendor/dav1d-1.5.4.tar.gz .build/vendor/zimg-3.0.6.tar.gz dist/Clipper-Sources/Dependencies/
cp .build/media/config.mak .build/media-configure.log dist/Clipper-Sources/Recipes/
cp scripts/build-*.sh scripts/build-zimg.py scripts/media-pkg-config.sh dist/Clipper-Sources/Recipes/
git archive HEAD -o dist/Clipper-Sources/Clipper-source.tar
cp docs/third-party-notices.txt dist/Clipper-Sources/
ditto -c -k --sequesterRsrc --keepParent dist/Clipper.app dist/Clipper-macOS-arm64.zip
ditto -c -k --keepParent dist/Clipper-Sources dist/Clipper-Sources.zip
echo 'Distribute Clipper-macOS-arm64.zip and Clipper-Sources.zip together.'
