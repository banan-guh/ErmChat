#!/usr/bin/env bash
# Builds the native emote codec shim (libwebp + native/emote_codec.c) for the
# host platform, producing build/native/libemote_codec.so.
#
# Used by the verification harness (test/verify/native_emote_codec_verify_test.dart):
#   EMOTE_CODEC_SO=build/native/libemote_codec.so flutter test test/verify/
#
# Expects libwebp source at third_party/libwebp (git submodule). Override with
# LIBWEBP_SRC for a scratch checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBWEBP_SRC="${LIBWEBP_SRC:-$ROOT/third_party/libwebp}"
BUILD_DIR="$ROOT/build/native"
OUT="$BUILD_DIR/libemote_codec.so"

if [ ! -f "$LIBWEBP_SRC/CMakeLists.txt" ]; then
  echo "libwebp source not found at $LIBWEBP_SRC" >&2
  echo "(run 'git submodule update --init' or set LIBWEBP_SRC)" >&2
  exit 1
fi

# Wipe a stale CMake cache (source dir changed, e.g. moved from a scratch checkout
# to the submodule).
if [ -f "$BUILD_DIR/libwebp/CMakeCache.txt" ] && ! grep -q "CMAKE_HOME_DIRECTORY:INTERNAL=$LIBWEBP_SRC$" "$BUILD_DIR/libwebp/CMakeCache.txt"; then
  rm -rf "$BUILD_DIR/libwebp"
fi

# Static libwebp with PIC objects so the shim can link them into a shared lib.
cmake -S "$LIBWEBP_SRC" -B "$BUILD_DIR/libwebp" \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF \
  -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
  -DWEBP_BUILD_LIBWEBPMUX=OFF -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_EXTRAS=OFF \
  -DWEBP_BUILD_WEBP_JS=OFF
cmake --build "$BUILD_DIR/libwebp" -j"$(nproc)"

cc -O2 -fPIC -shared -I"$LIBWEBP_SRC" -I"$ROOT/native" \
  -o "$OUT" "$ROOT/native/emote_codec.c" \
  "$BUILD_DIR/libwebp/libwebpdemux.a" "$BUILD_DIR/libwebp/libwebp.a" \
  -lm -lpthread

echo "built $OUT"
