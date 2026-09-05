#!/bin/bash
# Build an unmodified, LGPL-only FFmpeg executable for Apple Silicon.
# All FFmpeg libraries are static; dynamic dependencies must be Apple system libraries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${CHANNELDECK_BUILD_ROOT:-$REPO_ROOT/.release-build}"
VERSION=8.0.1
SHA256=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
ARCHIVE="$BUILD_ROOT/downloads/ffmpeg-$VERSION.tar.xz"
SOURCE="$BUILD_ROOT/sources/ffmpeg-$VERSION"
BUILD="$BUILD_ROOT/ffmpeg-build"
PREFIX="$BUILD_ROOT/ffmpeg"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "This recipe requires an Apple Silicon Mac and Xcode command-line tools." >&2
    exit 1
fi
mkdir -p "$BUILD_ROOT/downloads" "$BUILD_ROOT/sources" "$BUILD" "$PREFIX/bin" "$PREFIX/source"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$ARCHIVE"
fi
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$SHA256" ]]; then
    echo "FFmpeg source checksum mismatch; refusing to build." >&2
    exit 1
fi
if [[ ! -f "$SOURCE/configure" ]]; then
    tar -xJf "$ARCHIVE" -C "$BUILD_ROOT/sources"
fi

cd "$BUILD"
# Disable discovery of Homebrew libraries, GPL/version3/nonfree components,
# and optional third-party libraries. Apple frameworks provide hardware codecs
# and HTTPS. Preserve the built-in demuxers, decoders, and filters used for IPTV.
"$SOURCE/configure" \
    --prefix="$PREFIX" \
    --arch=arm64 --target-os=darwin \
    --cc="$(xcrun --find clang)" \
    --sysroot="$(xcrun --sdk macosx --show-sdk-path)" \
    --host-cflags="-isysroot $(xcrun --sdk macosx --show-sdk-path)" \
    --host-ldflags="-isysroot $(xcrun --sdk macosx --show-sdk-path)" \
    --extra-cflags=-mmacosx-version-min=14.0 \
    --extra-ldflags=-mmacosx-version-min=14.0 \
    --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 \
    --enable-static --disable-shared --disable-debug --disable-doc \
    --disable-ffplay --disable-ffprobe \
    --enable-videotoolbox --enable-audiotoolbox --enable-securetransport \
    > "$BUILD_ROOT/ffmpeg-configure.log" 2>&1
# Keep the default modest so development does not monopolize a watching Mac.
make -j "${CHANNELDECK_BUILD_JOBS:-4}" ffmpeg > "$BUILD_ROOT/ffmpeg-build.log" 2>&1
install -m 755 ffmpeg "$PREFIX/bin/ffmpeg"
strip -x "$PREFIX/bin/ffmpeg"

if otool -L "$PREFIX/bin/ffmpeg" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/Library/)' ; then
    echo "Unexpected non-system dynamic library in FFmpeg." >&2
    exit 1
fi
"$PREFIX/bin/ffmpeg" -L > "$PREFIX/LICENSE.txt" 2>&1
if ! grep -q 'GNU Lesser General' "$PREFIX/LICENSE.txt"; then
    echo "Expected LGPL FFmpeg build." >&2
    exit 1
fi
cp "$SOURCE/COPYING.LGPLv2.1" "$PREFIX/source/COPYING.LGPLv2.1"
cp "$SOURCE/LICENSE.md" "$PREFIX/source/UPSTREAM-LICENSE.md"
cp "$ARCHIVE" "$PREFIX/source/"
cp "$SCRIPT_DIR/build_ffmpeg.sh" "$PREFIX/source/build_ffmpeg.sh"
"$PREFIX/bin/ffmpeg" -buildconf > "$PREFIX/source/configuration.txt" 2>&1
{
    xcodebuild -version
    xcrun clang --version
    xcrun --sdk macosx --show-sdk-version
} > "$PREFIX/source/toolchain.txt"
{
    printf 'FFmpeg %s — https://ffmpeg.org/\n\n' "$VERSION"
    printf 'This separate executable is licensed under LGPL 2.1 or later.\n'
    printf 'ChannelDeck invokes it as a subprocess and does not link to its libraries.\n'
    printf 'ChannelDeck\047s noncommercial license does not apply to FFmpeg.\n'
    printf 'FFmpeg source is unmodified. GPL, nonfree, and version3 options are disabled.\n\n'
    printf 'Corresponding source archive: ffmpeg-%s.tar.xz\nSHA-256: %s\n' "$VERSION" "$SHA256"
    printf 'The release includes the source archive, upstream license, and build recipe.\n'
    printf 'Build with: bash Scripts/build_ffmpeg.sh from the ChannelDeck source checkout.\n'
    printf 'Requires Apple Silicon, macOS 14+, and Xcode command-line tools.\n'
    printf 'No third-party libraries or Homebrew installation are required.\n'
} > "$PREFIX/NOTICE.txt"
# Include the complete LGPL text with the binary, not just FFmpeg's short notice.
cp "$SOURCE/COPYING.LGPLv2.1" "$PREFIX/LICENSE.txt"
printf 'Standalone FFmpeg ready: %s\n' "$PREFIX/bin/ffmpeg"
