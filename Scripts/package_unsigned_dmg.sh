#!/bin/bash
# Build an Apple Silicon testing distribution. Ad hoc signing is NOT Developer ID
# signing or notarization; macOS will still require the user's explicit approval.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(awk '/^[[:space:]]*MARKETING_VERSION:/ { print $2; exit }' project.yml)"
case "$VERSION" in
  ''|*[!0-9.]*) echo "Invalid MARKETING_VERSION in project.yml" >&2; exit 1 ;;
esac
BUILD="$ROOT/.release-build"
FFMPEG="$BUILD/ffmpeg"
DIST="$ROOT/dist"
NAME="ChannelDeck-$VERSION-arm64"
DMG="$DIST/$NAME.dmg"
SOURCE_ARCHIVE="$DIST/ChannelDeck-$VERSION-ffmpeg-source.tar.gz"

for tool in xcodegen xcodebuild hdiutil codesign lipo otool ditto shasum; do
  command -v "$tool" >/dev/null || { echo "Required tool not found: $tool" >&2; exit 1; }
done
[[ "$(uname -m)" == arm64 ]] || { echo "Build this release on an Apple Silicon Mac." >&2; exit 1; }
for output in "$DMG" "$DMG.sha256" "$SOURCE_ARCHIVE" "$SOURCE_ARCHIVE.sha256" "$DIST/$NAME-NOTICES.txt"; do
  [[ ! -e "$output" ]] || { echo "Refusing to overwrite existing release: $output" >&2; exit 1; }
done
[[ -x "$FFMPEG/bin/ffmpeg" && -f "$FFMPEG/NOTICE.txt" && -f "$FFMPEG/LICENSE.txt" && -f "$FFMPEG/source/configuration.txt" && -f "$FFMPEG/source/build_ffmpeg.sh" ]] || {
  echo "Build bundled FFmpeg first: bash Scripts/build_ffmpeg.sh" >&2; exit 1;
}
compgen -G "$FFMPEG/source/ffmpeg-*.tar.xz" >/dev/null || { echo "Corresponding FFmpeg source archive is missing." >&2; exit 1; }

# Only system libraries may be dynamically linked. Every
# Mach-O is checked again after copying; Homebrew/user-library dependencies fail.
verify_binary() {
  local binary="$1" dependency arch runtime sdk
  arch="$(lipo -archs "$binary")"
  [[ "$arch" == arm64 ]] || { echo "Expected arm64 only: $binary ($arch)" >&2; exit 1; }
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      @rpath/libswiftCompatibilitySpan.dylib)
        [[ -n "${APP:-}" && -f "$APP/Contents/Frameworks/libswiftCompatibilitySpan.dylib" ]] || {
          echo "Bundled Swift compatibility runtime missing for $binary" >&2; exit 1;
        }
        ;;
      @rpath/libswift*.dylib)
        # Xcode may express OS-shipped Swift runtimes through @rpath; require
        # the matching runtime in the active macOS SDK rather than allow any rpath.
        runtime="${dependency#@rpath/}"
        sdk="$(xcrun --sdk macosx --show-sdk-path)"
        [[ -f "$sdk/usr/lib/swift/${runtime%.dylib}.tbd" ]] || {
          echo "Unresolved Swift runtime in $binary: $dependency" >&2; exit 1;
        }
        ;;
      *) echo "Non-system dependency in $binary: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//')
}
verify_binary "$FFMPEG/bin/ffmpeg"
FFMPEG_CONFIG="$("$FFMPEG/bin/ffmpeg" -hide_banner -buildconf 2>&1)"
if [[ "$FFMPEG_CONFIG" == *--enable-gpl* || "$FFMPEG_CONFIG" == *--enable-nonfree* || "$FFMPEG_CONFIG" == *--enable-version3* ]]; then
  echo "FFmpeg must be the LGPL-only build produced by Scripts/build_ffmpeg.sh." >&2
  exit 1
fi

mkdir -p "$BUILD" "$DIST"
STAGE="$(mktemp -d "$BUILD/dmg-stage.XXXXXX")"
echo "Staging release in $STAGE (retained for inspection)."
xcodegen generate
xcodebuild -quiet -project ChannelDeck.xcodeproj -scheme ChannelDeck -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" -destination 'generic/platform=macOS' \
  -jobs 4 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build

APP="$STAGE/ChannelDeck.app"
ditto "$BUILD/DerivedData/Build/Products/Release/ChannelDeck.app" "$APP"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || {
  echo "Built app version does not match release version." >&2; exit 1;
}
ditto "$FFMPEG/bin/ffmpeg" "$APP/Contents/MacOS/ffmpeg"
NOTICES="$APP/Contents/Resources/ThirdPartyNotices"
mkdir -p "$NOTICES/FFmpeg"
ditto "$FFMPEG/NOTICE.txt" "$NOTICES/FFmpeg/NOTICE.txt"
ditto "$FFMPEG/LICENSE.txt" "$NOTICES/FFmpeg/LICENSE.txt"
ditto "$FFMPEG/source/configuration.txt" "$NOTICES/FFmpeg/configuration.txt"
ditto LICENSE.md "$APP/Contents/Resources/LICENSE.md"

# Include license and notice files from every resolved package, including nested
# vendored code such as BoringSSL. Keep paths so notices retain their provenance.
CHECKOUTS="$BUILD/DerivedData/SourcePackages/checkouts"
[[ -d "$CHECKOUTS" ]] || { echo "Resolved Swift package checkouts missing." >&2; exit 1; }
while IFS= read -r -d '' notice; do
  relative="${notice#"$CHECKOUTS/"}"
  mkdir -p "$NOTICES/SwiftPackages/$(dirname "$relative")"
  ditto "$notice" "$NOTICES/SwiftPackages/$relative"
done < <(find "$CHECKOUTS" -type d -name .git -prune -o -type f \( -iname '*license*' -o -iname '*notice*' -o -iname 'copying*' -o -iname 'copyright*' \) -print0)
[[ -d "$NOTICES/SwiftPackages" ]] || { echo "No Swift dependency notices found." >&2; exit 1; }

# Generate plain text resources from this reviewed script, without provider data.
printf '%s\n' \
  'ChannelDeck third-party software' \
  '' \
  'ChannelDeck is licensed under PolyForm Noncommercial 1.0.0.' \
  'That license applies to ChannelDeck, not the separately licensed dependencies.' \
  '' \
  'FFmpeg is distributed as a separate executable under LGPL 2.1 or later.' \
  'Its license, build configuration, and acknowledgment are in FFmpeg/.' \
  'The exact FFmpeg source and build recipe accompany this DMG as:' \
  "ChannelDeck-$VERSION-ffmpeg-source.tar.gz" \
  'FFmpeg remains separately licensed and may be replaced with a compatible build.' \
  'FFmpeg project: https://ffmpeg.org/' \
  '' \
  'Swift dependency license and notice files are preserved in SwiftPackages/.' \
  > "$NOTICES/THIRD-PARTY-NOTICES.txt"

while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    # Xcode copies universal Swift compatibility libraries even for arm64-only
    # app targets. Thin those staged copies before verifying and signing them.
    if [[ "$(lipo -archs "$binary")" != arm64 ]]; then
      lipo "$binary" -thin arm64 -output "$binary.arm64"
      mv "$binary.arm64" "$binary"
    fi
    verify_binary "$binary"
    codesign --force --sign - --options runtime --timestamp=none "$binary"
  fi
done < <(find "$APP" -type f -print0)
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ln -s /Applications "$STAGE/Applications"
printf '%s\n' \
  'Install ChannelDeck' \
  '' \
  '1. Drag ChannelDeck.app into Applications.' \
  '2. Open ChannelDeck from Applications.' \
  '3. If macOS blocks this testing build, open System Settings > Privacy & Security' \
  '   and choose Open Anyway for ChannelDeck, then confirm opening it.' \
  '' \
  'This build is ad hoc signed, not signed by an identified Apple developer or notarized.' \
  'Only approve it if you trust the source of this download.' \
  'Requires an Apple Silicon Mac running macOS 15 or later. FFmpeg is included.' \
  'No channels or playlists are included; add your own playlist in the app.' \
  '' \
  'Project: https://github.com/cevatkerim/ChannelDeck' \
  > "$STAGE/Install ChannelDeck.txt"
ditto "$NOTICES" "$STAGE/ThirdPartyNotices"
ditto LICENSE.md "$STAGE/LICENSE.md"

tar -czf "$SOURCE_ARCHIVE" -C "$FFMPEG" source LICENSE.txt NOTICE.txt
ditto "$NOTICES/THIRD-PARTY-NOTICES.txt" "$DIST/$NAME-NOTICES.txt"
hdiutil create -volname "ChannelDeck $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG"
hdiutil verify "$DMG"
(cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
(cd "$DIST" && shasum -a 256 "ChannelDeck-$VERSION-ffmpeg-source.tar.gz" > "ChannelDeck-$VERSION-ffmpeg-source.tar.gz.sha256")
echo "Created $DMG"
echo "Distribute the DMG, its checksum, FFmpeg source archive and checksum, and notices together."
