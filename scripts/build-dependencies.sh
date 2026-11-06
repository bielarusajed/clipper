#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=14.0
export PATH="$ROOT/.build/build-tools/bin:$PATH"
mkdir -p .build/vendor .build/media/lib .build/media/include
if [[ ! -x .build/build-tools/bin/meson ]]; then
  python3 -m venv .build/build-tools
  .build/build-tools/bin/pip install 'meson==1.9.1' 'ninja==1.13.0'
fi
if [[ ! -f .build/vendor/dav1d-1.5.4.tar.gz ]]; then
  curl -fL https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.gz -o .build/vendor/dav1d-1.5.4.tar.gz
fi
if [[ ! -f .build/vendor/zimg-3.0.6.tar.gz ]]; then
  curl -fL https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.6.tar.gz -o .build/vendor/zimg-3.0.6.tar.gz
fi
tar -xf .build/vendor/dav1d-1.5.4.tar.gz -C .build/vendor
tar -xf .build/vendor/zimg-3.0.6.tar.gz -C .build/vendor
if [[ ! -f .build/vendor/dav1d-build/build.ninja ]]; then
  meson setup .build/vendor/dav1d-build .build/vendor/dav1d-1.5.4 \
    --prefix="$ROOT/.build/media" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Denable_tools=false -Denable_tests=false -Ddefault_library=shared \
    -Dc_args='-mmacosx-version-min=14.0' -Dc_link_args='-mmacosx-version-min=14.0'
fi
ninja -C .build/vendor/dav1d-build install
python3 scripts/build-zimg.py
