#!/bin/bash
# Self-contained review app and matching dependency sources, kept in this worktree.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then echo 'Commit before packaging matching sources.' >&2; exit 1; fi
bash scripts/build-app.sh
APP="$PWD/dist/Clipper URL Range Review.app"
if [[ -d "$APP" ]]; then mv "$APP" ".build/previous-url-range-review-$(uuidgen).app"; fi
mv dist/Clipper.app "$APP"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1]) / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info.update(CFBundleName='Clipper URL Range Review', CFBundleDisplayName='Clipper URL Range Review',
            CFBundleIdentifier='app.clipper.video.review.url-range-import')
info.pop('CFBundleDocumentTypes', None)
info.pop('UTImportedTypeDeclarations', None)
path.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
SOURCES="$PWD/dist/Clipper-URL-Range-Review-Sources"
if [[ -d "$SOURCES" ]]; then mv "$SOURCES" ".build/previous-range-sources-$(uuidgen)"; fi
mkdir -p "$SOURCES/Dependencies" "$SOURCES/Recipes"
cp .build/vendor/ffmpeg-8.0.1.tar.xz .build/vendor/dav1d-1.5.4.tar.gz .build/vendor/zimg-3.0.6.tar.gz "$SOURCES/Dependencies/"
cp .build/media/tls-patch.sha256 patches/ffmpeg-8.0.1-tls-verify-default.patch "$SOURCES/Dependencies/"
cp .build/media/config.mak .build/media-configure.log "$SOURCES/Recipes/"
cp scripts/build-*.sh scripts/build-zimg.py scripts/media-pkg-config.sh "$SOURCES/Recipes/"
git archive HEAD -o "$SOURCES/Clipper-source.tar"
cp docs/third-party-notices.txt "$SOURCES/"
python3 - "$APP" "$SOURCES" <<'PY'
import hashlib, json, pathlib, subprocess, sys
app, sources = map(pathlib.Path, sys.argv[1:])
receipt = {'commit': subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
           'branch': subprocess.check_output(['git','branch','--show-current'], text=True).strip(),
           'bundleIdentifier': 'app.clipper.video.review.url-range-import',
           'sha256': {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(app.rglob('*')) if p.is_file()}}
(sources / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
(sources / 'README.txt').write_text('Extract Clipper-source.tar. Run bash scripts/build-app.sh to rebuild.\n'
    'Place the supplied dependency archives in .build/vendor first for an offline media build.\n'
    'dav1d/zimg require the build tools documented in README.md.\n'
    'Distribute this source ZIP with the matching review app ZIP.\n')
PY
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Clipper-URL-Range-Review-macOS-arm64.zip
ditto -c -k --keepParent "$SOURCES" dist/Clipper-URL-Range-Review-Sources.zip
printf '%s\n' "$PWD/dist/Clipper-URL-Range-Review-macOS-arm64.zip" "$PWD/dist/Clipper-URL-Range-Review-Sources.zip"
