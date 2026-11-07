#!/bin/bash
# Private, shared-library subtitle stack. No Homebrew runtime dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="-O2 -isysroot $SDKROOT -mmacosx-version-min=14.0"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$ROOT/.build/media/lib -Wl,-rpath,$ROOT/.build/media/lib"
mkdir -p .build/vendor .build/media .build/build-tools
# Meson/Ninja are build tools only. A local venv is also used by build-dependencies.
if [[ ! -x .build/build-tools/bin/meson ]]; then
  python3 -m venv .build/build-tools
  .build/build-tools/bin/pip install 'meson==1.9.1' 'ninja==1.13.0'
fi
export PATH="$ROOT/.build/build-tools/bin:$PATH"
fetch() {
  local name="$1" url="$2"
  [[ -f ".build/vendor/$name.tar.xz" ]] || curl -fL --retry 3 "$url" -o ".build/vendor/$name.tar.xz"
  local receipt
  receipt=$(awk -v file=".build/vendor/$name.tar.xz" '$2 == file' scripts/subtitle-sources.sha256)
  [[ -n "$receipt" ]] || { echo "Missing source checksum for $name" >&2; exit 1; }
  echo "$receipt" | shasum -a 256 -c -
  tar -xf ".build/vendor/$name.tar.xz" -C .build/vendor
}
fetch pkgconf-2.3.0 https://distfiles.ariadne.space/pkgconf/pkgconf-2.3.0.tar.xz
fetch freetype-2.13.3 https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz
fetch fribidi-1.0.16 https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz
fetch harfbuzz-10.4.0 https://github.com/harfbuzz/harfbuzz/releases/download/10.4.0/harfbuzz-10.4.0.tar.xz
fetch libass-0.17.3 https://github.com/libass/libass/releases/download/0.17.3/libass-0.17.3.tar.xz
(cd .build/vendor/pkgconf-2.3.0; ./configure --prefix="$ROOT/.build/build-tools" --disable-shared; make -j8; make install)
export PKG_CONFIG="$ROOT/.build/build-tools/bin/pkgconf"
export PKG_CONFIG_LIBDIR="$ROOT/.build/media/lib/pkgconfig"
export PKG_CONFIG_PATH=""
(cd .build/vendor/freetype-2.13.3; ./configure --prefix="$ROOT/.build/media" --enable-shared --disable-static --without-harfbuzz --without-png --without-bzip2 --without-brotli --with-zlib=no; make -j8; make install)
meson setup --wipe .build/vendor/fribidi-build .build/vendor/fribidi-1.0.16 --prefix="$ROOT/.build/media" --libdir=lib --buildtype=release -Ddefault_library=shared -Ddocs=false -Dbin=false -Dtests=false
ninja -C .build/vendor/fribidi-build install
meson setup --wipe .build/vendor/harfbuzz-build .build/vendor/harfbuzz-10.4.0 --prefix="$ROOT/.build/media" --libdir=lib --buildtype=release -Ddefault_library=shared -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled -Dgraphite2=disabled -Dcoretext=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled
ninja -C .build/vendor/harfbuzz-build install
(cd .build/vendor/libass-0.17.3; ./configure --prefix="$ROOT/.build/media" --enable-shared --disable-static --disable-fontconfig --enable-coretext --disable-libunibreak --disable-asm; make -j8; make install)
