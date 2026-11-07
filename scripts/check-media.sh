#!/bin/bash
# Reject stale offline or unpatched media caches before staging an app.
set -euo pipefail
cd "$(dirname "$0")/.."
test -x .build/media/bin/ffmpeg
test -f .build/media/lib/libass.9.dylib
grep -q '^CONFIG_ASS_FILTER=yes$' .build/media/config.mak
grep -q '^CONFIG_ASS_ENCODER=yes$' .build/media/config.mak
grep -q '^CONFIG_SECURETRANSPORT=yes$' .build/media/config.mak
grep -q '^CONFIG_HTTPS_PROTOCOL=yes$' .build/media/config.mak
test "$(cat .build/media/tls-patch.sha256)" = "$(shasum -a 256 patches/ffmpeg-8.0.1-tls-verify-default.patch | awk '{print $1}')"
.build/media/bin/ffmpeg -hide_banner -h protocol=tls 2>&1 | grep 'tls_verify.*(default 1)' > /dev/null
