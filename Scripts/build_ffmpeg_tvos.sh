#!/bin/bash
# Reproducible LGPL-only library build. No FFmpeg executable is shipped on tvOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${CHANNELDECK_TV_BUILD_ROOT:-$ROOT/.build/ffmpeg-tvos}"
VERSION=8.0.1
SHA256=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
ARCHIVE="$BUILD_ROOT/downloads/ffmpeg-$VERSION.tar.xz"
SOURCE="$BUILD_ROOT/source/ffmpeg-$VERSION"
mkdir -p "$BUILD_ROOT/downloads" "$BUILD_ROOT/source"
if [[ ! -f "$ARCHIVE" ]]; then
  curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$ARCHIVE"
fi
[[ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" == "$SHA256" ]] || { echo 'FFmpeg checksum mismatch' >&2; exit 1; }
[[ -f "$SOURCE/configure" ]] || tar -xf "$ARCHIVE" -C "$BUILD_ROOT/source"
for PLATFORM in "${@:-appletvos appletvsimulator}"; do
  for SDK in $PLATFORM; do
    case "$SDK" in
      appletvos) TARGET=arm64-apple-tvos18.0 ;;
      appletvsimulator) TARGET=arm64-apple-tvos18.0-simulator ;;
      *) echo "Unsupported SDK: $SDK" >&2; exit 1 ;;
    esac
    PREFIX="$BUILD_ROOT/$SDK"
    BUILD="$BUILD_ROOT/build-$SDK"
    mkdir -p "$BUILD" "$PREFIX"
    cd "$BUILD"
    if [[ ! -f "$PREFIX/.complete-$VERSION" ]]; then
      "$SOURCE/configure" --prefix="$PREFIX" --arch=arm64 --target-os=darwin \
        --enable-cross-compile --cc="$(xcrun --sdk "$SDK" --find clang)" \
        --sysroot="$(xcrun --sdk "$SDK" --show-sdk-path)" \
        --extra-cflags="-target $TARGET" --extra-ldflags="-target $TARGET" \
        --disable-autodetect --disable-gpl --disable-version3 --disable-nonfree \
        --enable-static --disable-shared --enable-pic --disable-debug --disable-doc \
        --disable-programs --disable-avdevice --disable-avfilter --disable-encoders \
        --disable-muxers --disable-devices --disable-filters \
        --enable-videotoolbox --enable-audiotoolbox --enable-securetransport \
        > "$BUILD/configure.log" 2>&1
      make -j "${CHANNELDECK_BUILD_JOBS:-6}" > "$BUILD/build.log" 2>&1
      make install > "$BUILD/install.log" 2>&1
      cp "$SOURCE/COPYING.LGPLv2.1" "$PREFIX/LICENSE.txt"
      cp "$BUILD/config.h" "$PREFIX/build-configuration.h"
      touch "$PREFIX/.complete-$VERSION"
    fi
    echo "FFmpeg $VERSION libraries ready: $SDK"
  done
done
