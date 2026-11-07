#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="/opt/homebrew/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
VERSION=8.0.1
# Never configure, clean or install through a shared worktree's dependency symlinks.
if [[ -L .build/media || -L .build/vendor || -L .build/vendor/ffmpeg-$VERSION ]]; then
  echo 'Media builds require private .build/media and .build/vendor directories.' >&2; exit 1
fi
mkdir -p .build/vendor .build/media
if [[ ! -f .build/media/lib/libdav1d.7.dylib || ! -f .build/media/lib/libzimg.2.dylib ]]; then
  bash scripts/build-dependencies.sh
fi
if [[ ! -f .build/vendor/ffmpeg-$VERSION.tar.xz ]]; then
  curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o ".build/vendor/ffmpeg-$VERSION.tar.xz"
fi
if [[ ! -d .build/vendor/ffmpeg-$VERSION ]]; then
  tar -xf ".build/vendor/ffmpeg-$VERSION.tar.xz" -C .build/vendor
fi
PATCH="$ROOT/patches/ffmpeg-8.0.1-tls-verify-default.patch"
if ! grep -q 'Modified by Clipper on 2026-11-07' ".build/vendor/ffmpeg-$VERSION/libavformat/tls.h"; then
  (cd ".build/vendor/ffmpeg-$VERSION"; patch --dry-run -p1 -N < "$PATCH"; patch -p1 -N < "$PATCH")
fi
(cd ".build/vendor/ffmpeg-$VERSION"; patch -R --dry-run -p1 < "$PATCH")
if [[ "$(grep -c '^#define TLS_VERIFY_DEFAULT 1$' ".build/vendor/ffmpeg-$VERSION/libavformat/tls.h")" != 1 ]] || grep -q '^#define TLS_VERIFY_DEFAULT 0$' ".build/vendor/ffmpeg-$VERSION/libavformat/tls.h"; then
  echo 'Unexpected TLS verification patch state.' >&2; exit 1
fi
# The package script copies these self-built libraries into the app.
export PKG_CONFIG_PATH="$ROOT/.build/media/lib/pkgconfig"
cd ".build/vendor/ffmpeg-$VERSION"
# FFmpeg does not relink existing dylibs when only configure link paths change.
if [[ -f ffbuild/config.mak ]]; then make clean > "$ROOT/.build/media-clean.log" 2>&1; fi
./configure --prefix="$ROOT/.build/media" --cc="$(xcrun --find clang)" \
  --pkg-config="$ROOT/scripts/media-pkg-config.sh" \
  --disable-gpl --disable-nonfree --disable-version3 --disable-autodetect \
  --enable-shared --disable-static --disable-debug --disable-doc --enable-network --enable-securetransport \
  --disable-avdevice --disable-ffplay --enable-videotoolbox --enable-audiotoolbox \
  --enable-libdav1d --enable-libzimg --enable-zlib --disable-encoders \
  --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac_at,pcm_s16le,png \
  --extra-cflags="-isysroot $SDKROOT -mmacosx-version-min=14.0" \
  --extra-ldflags="-isysroot $SDKROOT -Wl,-rpath,$ROOT/.build/media/lib" > "$ROOT/.build/media-configure.log" 2>&1
make -j"${CLIPPER_BUILD_JOBS:-4}" > "$ROOT/.build/media-build.log" 2>&1
make install >> "$ROOT/.build/media-build.log" 2>&1
cp ffbuild/config.mak "$ROOT/.build/media/config.mak"
shasum -a 256 "$PATCH" | awk '{print $1}' > "$ROOT/.build/media/tls-patch.sha256"
bash "$ROOT/scripts/check-media.sh"
echo "Media engine built in $ROOT/.build/media"
