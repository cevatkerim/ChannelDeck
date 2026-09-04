# ChannelDeck

ChannelDeck is a native macOS IPTV player built with SwiftUI, AVKit, AVFoundation, SwiftData, Keychain Services, and CryptoKit. It supports multiple remote M3U playlists, channel groups, search, favorites, recents, XMLTV now/next data, Picture in Picture, fullscreen playback, and AirPlay.

The application contains no bundled playlist or credentials. Add a playlist on first launch; its URL is stored in the macOS Keychain, and the last-known-good playlist snapshot is encrypted before being written to Application Support.

## Requirements

- macOS 15 or newer
- Xcode 16 or newer with Swift 6
- XcodeGen if `project.yml` is changed and the project needs regenerating
- FFmpeg 7 or newer for AirPlay audio compatibility during development (`brew install ffmpeg`). A distributable build can place an appropriately licensed `ffmpeg` auxiliary executable inside the app bundle.

## Run

1. Open `ChannelDeck.xcodeproj`.
2. Select the ChannelDeck target and choose your personal development team under Signing & Capabilities.
3. Build and run the ChannelDeck scheme.
4. Paste an HTTPS M3U playlist URL into the first-run sheet. The EPG URL is discovered from `url-tvg`, or you can provide an HTTPS override.

ChannelDeck requires HTTPS for playlist and EPG downloads. The configured provider's media URLs use HTTP and redirect to rotating origin hosts, so `Info.plist` enables App Transport Security's media-only exception for AVFoundation playback. This does not enable arbitrary HTTP for the app's playlist or EPG networking. Direct HTTP channel URLs are still accepted only from the configured provider host.

## Secure AirPlay relay

Direct AirPlay hands the media URL to the receiver. Providers that redirect to plain HTTP can therefore play on the Mac while failing on Apple TV. ChannelDeck's optional relay gives the receiver a publicly trusted HTTPS URL while the stream stays on the local network.

1. In Cloudflare, create an API token scoped to the desired zone with **Zone DNS Edit** and **Zone Read** permissions.
2. Open ChannelDeck Settings and enter the zone domain (for example, `example.com`), the optional Cloudflare account ID, and the API token.
3. Keep **Production (trusted)** selected for Apple TV. The staging option only validates ACME/DNS setup and is intentionally not receiver-trusted.
4. Choose **Set Up Relay**. ChannelDeck detects the current RFC 1918 LAN address, creates a unique DNS-only `iptv-xxxxxxxx` A record, waits until the exact DNS-01 TXT value is visible through encrypted public DNS, completes the Let's Encrypt challenge, and starts a local HTTPS listener.

The API token and certificate key material are stored in Keychain. DNS records carry an installation-specific ownership comment, and Reset removes only the record owned by that installation. Comments work on Cloudflare zones whose DNS record tag quota is zero. The relay exposes opaque, expiring session paths and never puts upstream source URLs in receiver-facing paths or errors.

For HLS playlists, the relay copies H.264 video without re-encoding and converts the first audio track to 48 kHz stereo AAC in a rolling local rendition. AVPlayer remains the app's native decoder and renderer; FFmpeg is used only to make the relay output compatible with Apple TV. ChannelDeck looks for a bundled auxiliary executable first, followed by `/opt/homebrew/bin/ffmpeg` and `/usr/local/bin/ffmpeg`. Provider URLs are never passed to the subprocess—the transcoder receives only an opaque local relay URL.

Continuous raw MPEG-TS source URLs still play directly on the Mac but are not relayed. The Mac must remain awake on the same LAN as the AirPlay receiver. Some routers' DNS-rebinding protection may block public hostnames that resolve to private addresses; allow the generated hostname if necessary.

## Generate and test

```sh
xcodegen generate
xcodebuild -project ChannelDeck.xcodeproj -scheme ChannelDeck \
  -derivedDataPath .xcode-derived CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ChannelDeck.xcodeproj -scheme ChannelDeck \
  -derivedDataPath .xcode-derived -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

## Project layout

- `ChannelDeck/App`: application entry point and orchestration
- `ChannelDeck/Core`: secret-free domain values
- `ChannelDeck/Networking`: HTTPS fetching and gzip handling
- `ChannelDeck/Persistence`: SwiftData records
- `ChannelDeck/Playback`: AVPlayer, native player view, and AirPlay picker
- `ChannelDeck/Relay`: Cloudflare-backed HTTPS HLS relay and LAN discovery
- `ChannelDeck/ACME`: Let's Encrypt DNS-01 issuance and Keychain certificate storage
- `ChannelDeck/Security`: Keychain and encrypted playlist cache
- `ChannelDeck/Services`: M3U and XMLTV parsers
- `ChannelDeck/UI`: native SwiftUI interface
- `ChannelDeckTests`: parser, network, security, and playback tests

See `plan.md` for the implementation specification and explicit v1 boundaries.
