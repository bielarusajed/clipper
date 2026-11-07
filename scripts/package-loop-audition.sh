#!/bin/bash
# Build the isolated review app and its matching redistributable sources.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit the working tree before packaging matching sources.' >&2
  exit 1
fi
bash scripts/build-app.sh
APP="$PWD/dist/Clipper Loop Audition.app"
if [[ -d "$APP" ]]; then mv "$APP" "$PWD/.build/previous-loop-app-$(uuidgen).app"; fi
mv dist/Clipper.app "$APP"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
info.update(CFBundleName='Clipper Loop Audition', CFBundleDisplayName='Clipper Loop Audition',
            CFBundleIdentifier='app.clipper.review.loop-audition')
info.pop('CFBundleDocumentTypes', None)
info.pop('UTImportedTypeDeclarations', None)
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
SOURCES="$PWD/dist/Clipper-Loop-Audition-Sources"
if [[ -d "$SOURCES" ]]; then mv "$SOURCES" "$PWD/.build/previous-loop-sources-$(uuidgen)"; fi
mkdir -p "$SOURCES/Dependencies" "$SOURCES/Recipes"
cp .build/vendor/ffmpeg-8.0.1.tar.xz .build/vendor/dav1d-1.5.4.tar.gz .build/vendor/zimg-3.0.6.tar.gz "$SOURCES/Dependencies/"
cp .build/media/config.mak .build/media-configure.log "$SOURCES/Recipes/"
cp scripts/build-*.sh scripts/build-zimg.py scripts/media-pkg-config.sh "$SOURCES/Recipes/"
git archive HEAD -o "$SOURCES/Clipper-source.tar"
git rev-parse HEAD > "$SOURCES/COMMIT.txt"
cp docs/third-party-notices.txt "$SOURCES/"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Clipper-Loop-Audition-macOS-arm64.zip
ditto -c -k --keepParent "$SOURCES" dist/Clipper-Loop-Audition-Sources.zip
echo 'Distribute both Clipper-Loop-Audition ZIPs together.'
