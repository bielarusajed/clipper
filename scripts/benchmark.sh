#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -O2 -fobjc-arc -isysroot "$SDKROOT" -I Sources/CMedia/include -I .build/media/include \
  scripts/benchmark.m Sources/CMedia/CMedia.m -L .build/media/lib -lavformat -lavcodec -lavutil -lswscale -lswresample \
  -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreImage -framework CoreMedia -framework CoreVideo \
  -Wl,-rpath,"$PWD/.build/media/lib" -o .build/benchmark
exec .build/benchmark "$@"
