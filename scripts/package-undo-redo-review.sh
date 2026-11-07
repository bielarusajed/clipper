#!/bin/bash
# Run from the committed feature worktree. Reuse only unchanged media/vendor inputs.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then echo 'Commit the working tree before packaging matching sources.' >&2; exit 1; fi
CLIPPER_REVIEW_BUILD=0 bash scripts/build-app.sh
APP='dist/Clipper Undo Redo Review.app'
SOURCES='dist/Clipper-Undo-Redo-Sources'
if [[ -d "$APP" ]]; then mv "$APP" ".build/previous-undo-review-$(uuidgen).app"; fi
mv dist/Clipper.app "$APP"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
info['CFBundleName'] = 'Clipper Undo Redo Review'
info['CFBundleDisplayName'] = 'Clipper Undo Redo Review'
info['CFBundleIdentifier'] = 'app.clipper.video.review.undo-redo'
# Open through the app's picker/drop target without advertising Finder associations.
info.pop('CFBundleDocumentTypes', None)
info.pop('UTImportedTypeDeclarations', None)
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
if [[ -d "$SOURCES" ]]; then mv "$SOURCES" ".build/previous-undo-sources-$(uuidgen)"; fi
mkdir -p "$SOURCES/Dependencies" "$SOURCES/Recipes"
cp .build/vendor/ffmpeg-8.0.1.tar.xz .build/vendor/dav1d-1.5.4.tar.gz .build/vendor/zimg-3.0.6.tar.gz "$SOURCES/Dependencies/"
cp .build/media/config.mak .build/media-configure.log "$SOURCES/Recipes/"
cp .build/media/tls-patch.sha256 patches/ffmpeg-8.0.1-tls-verify-default.patch "$SOURCES/Dependencies/"
cp .build/vendor/{pkgconf-2.3.0,freetype-2.13.3,fribidi-1.0.16,harfbuzz-10.4.0,libass-0.17.3}.tar.xz "$SOURCES/Dependencies/"
cp scripts/subtitle-sources.sha256 "$SOURCES/Recipes/"
cp scripts/build-*.sh scripts/build-zimg.py scripts/media-pkg-config.sh scripts/package-undo-redo-review.sh "$SOURCES/Recipes/"
git archive HEAD -o "$SOURCES/Clipper-source.tar"
cp docs/third-party-notices.txt "$SOURCES/"
{
  echo 'Clipper Undo Redo Review'
  git rev-parse HEAD
  echo 'Bundle: app.clipper.video.review.undo-redo'
  echo 'Production baseline: 0.4.3; review build only; ad-hoc signed'
  echo 'Build: bash scripts/package-undo-redo-review.sh'
} > "$SOURCES/BUILD.txt"
cp "$SOURCES/BUILD.txt" "$APP/Contents/Resources/Review-Build.txt"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Clipper-Undo-Redo-Review-macOS-arm64.zip
ditto -c -k --keepParent "$SOURCES" dist/Clipper-Undo-Redo-Sources.zip
shasum -a 256 dist/Clipper-Undo-Redo-Review-macOS-arm64.zip dist/Clipper-Undo-Redo-Sources.zip > dist/Clipper-Undo-Redo-SHA256.txt
echo "$PWD/dist/Clipper-Undo-Redo-Review-macOS-arm64.zip"
echo "$PWD/dist/Clipper-Undo-Redo-Sources.zip"
