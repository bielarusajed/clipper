#!/bin/bash
# Feature review build. Keep the production identity and version in assets intact.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit the working tree before packaging matching sources.' >&2
  exit 1
fi
bash scripts/build-app.sh
APP="dist/Clipper Export Handoff.app"
SOURCES="dist/Clipper-Export-Handoff-Sources"
if [[ -d "$APP" ]]; then mv "$APP" ".build/previous-export-handoff-$(uuidgen).app"; fi
mv dist/Clipper.app "$APP"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as file:
    info = plistlib.load(file)
info['CFBundleName'] = 'Clipper Export Handoff'
info['CFBundleDisplayName'] = 'Clipper Export Handoff'
info['CFBundleIdentifier'] = 'app.clipper.review.export-handoff'
info.pop('CFBundleDocumentTypes', None)
with open(path, 'wb') as file:
    plistlib.dump(info, file)
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
if [[ -d "$SOURCES" ]]; then mv "$SOURCES" ".build/previous-export-handoff-sources-$(uuidgen)"; fi
mkdir -p "$SOURCES/Dependencies" "$SOURCES/Recipes"
cp .build/vendor/ffmpeg-8.0.1.tar.xz .build/vendor/dav1d-1.5.4.tar.gz .build/vendor/zimg-3.0.6.tar.gz "$SOURCES/Dependencies/"
cp .build/media/config.mak .build/media-configure.log "$SOURCES/Recipes/"
cp scripts/build-*.sh scripts/build-zimg.py scripts/media-pkg-config.sh "$SOURCES/Recipes/"
git archive HEAD -o "$SOURCES/Clipper-source.tar"
git rev-parse HEAD > "$SOURCES/COMMIT.txt"
cp docs/third-party-notices.txt "$SOURCES/"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Clipper-Export-Handoff-macOS-arm64.zip
ditto -c -k --keepParent "$SOURCES" dist/Clipper-Export-Handoff-Sources.zip
shasum -a 256 dist/Clipper-Export-Handoff-macOS-arm64.zip dist/Clipper-Export-Handoff-Sources.zip > dist/Clipper-Export-Handoff-SHA256.txt
echo 'Distribute Clipper-Export-Handoff-macOS-arm64.zip and Clipper-Export-Handoff-Sources.zip together.'
