#!/bin/sh
# Small, explicit adapter for the two pinned build-time Homebrew dependencies.
case "$*" in --version) echo 1.9.5; exit 0 ;; esac
prefix="$(cd "$(dirname "$0")/.." && pwd)/.build/media"
case "$*" in
  *dav1d*) library=dav1d; version=1.5.4 ;;
  *zimg*) library=zimg; version=3.0.6 ;;
  *) exit 1 ;;
esac
test -d "$prefix/include" || exit 1
case "$*" in
  *--cflags*) echo "-I$prefix/include" ;;
  *--libs*) echo "-L$prefix/lib -l$library" ;;
  *--modversion*) echo "$version" ;;
esac
