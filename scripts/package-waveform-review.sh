#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit the working tree before packaging matching sources.' >&2
  exit 1
fi
bash scripts/build-app.sh
APP="$PWD/dist/Clipper Waveform Review.app"
SOURCES="$PWD/dist/Clipper-Waveform-Sources"
if [[ -d "$APP" ]]; then mv "$APP" ".build/previous-waveform-app-$(uuidgen).app"; fi
if [[ -d "$SOURCES" ]]; then mv "$SOURCES" ".build/previous-waveform-sources-$(uuidgen)"; fi
mv dist/Clipper.app "$APP"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info.update(CFBundleName='Clipper Waveform Review',
            CFBundleDisplayName='Clipper Waveform Review',
            CFBundleIdentifier='app.clipper.review.audio-waveform')
info.pop('CFBundleDocumentTypes', None)
info.pop('UTImportedTypeDeclarations', None)
path.write_bytes(plistlib.dumps(info))
PY
git rev-parse HEAD > "$APP/Contents/Resources/SourceRevision.txt"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$SOURCES/Dependencies" "$SOURCES/Recipes"
cp .build/vendor/ffmpeg-8.0.1.tar.xz .build/vendor/dav1d-1.5.4.tar.gz .build/vendor/zimg-3.0.6.tar.gz "$SOURCES/Dependencies/"
cp .build/media/config.mak .build/media-configure.log "$SOURCES/Recipes/"
cp scripts/build-*.sh scripts/build-zimg.py scripts/media-pkg-config.sh scripts/package-waveform-review.sh "$SOURCES/Recipes/"
git archive HEAD -o "$SOURCES/Clipper-source.tar"
git rev-parse HEAD > "$SOURCES/SourceRevision.txt"
cp docs/third-party-notices.txt "$SOURCES/"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Clipper-Waveform-Review-macOS-arm64.zip
ditto -c -k --keepParent "$SOURCES" dist/Clipper-Waveform-Sources.zip
echo "$APP"
echo "$PWD/dist/Clipper-Waveform-Review-macOS-arm64.zip"
echo "$PWD/dist/Clipper-Waveform-Sources.zip"
