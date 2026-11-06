#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="/opt/homebrew/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
VERSION=8.0.1
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
# The package script copies these self-built libraries into the app.
export PKG_CONFIG_PATH="$ROOT/.build/media/lib/pkgconfig"
cd ".build/vendor/ffmpeg-$VERSION"
# FFmpeg does not relink existing dylibs when only configure link paths change.
if [[ -f ffbuild/config.mak ]]; then make clean > "$ROOT/.build/media-clean.log" 2>&1; fi
./configure --prefix="$ROOT/.build/media" --cc="$(xcrun --find clang)" \
  --pkg-config="$ROOT/scripts/media-pkg-config.sh" \
  --disable-gpl --disable-nonfree --disable-version3 --disable-autodetect \
  --enable-shared --disable-static --disable-debug --disable-doc --disable-network \
  --disable-avdevice --disable-ffplay --enable-videotoolbox --enable-audiotoolbox \
  --enable-libdav1d --enable-libzimg --enable-zlib --disable-encoders \
  --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac_at,pcm_s16le,png \
  --extra-cflags="-isysroot $SDKROOT -mmacosx-version-min=14.0" \
  --extra-ldflags="-isysroot $SDKROOT -Wl,-rpath,$ROOT/.build/media/lib" > "$ROOT/.build/media-configure.log" 2>&1
make -j"$(sysctl -n hw.ncpu)" > "$ROOT/.build/media-build.log" 2>&1
make install >> "$ROOT/.build/media-build.log" 2>&1
cp ffbuild/config.mak "$ROOT/.build/media/config.mak"
echo "Media engine built in $ROOT/.build/media"
