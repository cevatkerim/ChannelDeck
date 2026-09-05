# ChannelDeck v1 — Native macOS IPTV App

## Summary

- Build a greenfield Swift 6/SwiftUI macOS application targeting macOS 15+, named **ChannelDeck**, with bundle identifier `com.kerimincedayi.ChannelDeck`.
- Ship a personally signed application with adaptive light/dark styling, multi-playlist management, search, groups, favorites, recents, now/next EPG, fullscreen, Picture in Picture, and AirPlay. Development builds may use an explicitly located Homebrew FFmpeg; distributable sandboxed builds require a separately built, relocatable, signed auxiliary executable.
- Use Apple's native media stack (`AVPlayer`, `AVPlayerView`, and `AVRoutePickerView`) for playback and rendering. When a secure AirPlay relay is configured, permit an isolated FFmpeg process to copy compatible H.264 video, convert receiver-incompatible audio to AAC, and use VideoToolbox to convert non-H.264 video to a receiver-compatible 1080p H.264 rendition; there is no alternate in-app player or renderer.
- Treat playlist, stream, and credential-bearing URLs as secrets. Never commit the supplied playlist URL or include it in logs, fixtures, screenshots, or plaintext persistence.

## Product and UX

- Use a three-column `NavigationSplitView`: library/playlists/groups in the sidebar, a searchable channel browser in the content column, and a large native player with programme information in the detail column.
- Provide first-run and playlist-management sheets for display name, HTTPS M3U URL, and optional EPG override. Support adding, editing, reordering, refreshing, and confirmed removal of multiple sources.
- Show channel logo, name, group, live state, current/next programme, and favorite state. Downsample logos off the main thread and share a bounded decoded-image cache across recycled list rows. Selecting a channel immediately replaces the single active player item.
- Include Favorites and the 20 most recent successfully played channels, native playback controls, fullscreen, Picture in Picture, an explicit AirPlay picker, loading/buffering indicators, retry actions, and useful empty/error states.
- Use native system typography, materials, semantic colors, SF Symbols, accessible labels, visible focus, keyboard navigation, and layouts that remain usable in compact and full-screen windows.

## Architecture and Data

- Parse extended M3U metadata including `tvg-id`, `tvg-name`, `tvg-logo`, `group-title`, `#EXTGRP`, and `url-tvg`, preserving playlist order and resolving relative URLs.
- Store non-secret source, channel, programme, favorite, recent, and refresh metadata with SwiftData. Derive stable channel identity from source UUID plus normalized TVG ID, name, and group.
- Store source URLs and encryption keys in Keychain. Encrypt each last-known-good raw playlist snapshot with CryptoKit AES-GCM before writing it under Application Support; stream URLs must never enter SwiftData.
- Fetch playlists every six hours and EPG feeds every twelve hours, plus manual refresh, using ETag/Last-Modified conditional requests. Replace cached state only after a complete successful fetch and parse; retain the previous catalogue on failure.
- Decompress `.xml.gz` feeds with system zlib, stream-parse XMLTV with `XMLParser`, match exact TVG IDs, and retain relevant programmes from two hours in the past through 36 hours ahead.
- Implement actor-isolated playlist/EPG repositories and secret storage, with a `@MainActor` observable application model and player controller.

## Playback, AirPlay, and Security

- Render through `AVPlayerView` and manage one shared `AVPlayer`. Observe item readiness, buffering, failure, time control, and external playback state; expose these as explicit playback states to SwiftUI.
- Bind a macOS `AVRoutePickerView` to the shared player, allow external playback, and visibly indicate when an external route is active. Keep the picker's toolbar identity stable when playback state changes, and never detach the shared player during transient SwiftUI view reconciliation because doing so cancels an active receiver handoff.
- Require HTTPS for playlist and EPG requests. Permit HTTP only for approved provider media because the configured provider redirects to rotating HTTP origin hosts; continue rejecting direct HTTP channel URLs from other providers with a clear security message. When preparing a distributable build, enable App Sandbox plus network client/server entitlements and embed the transcoder inside the app's signed code graph.
- Redact URLs from errors and diagnostics, cancel obsolete refresh/playback tasks, prevent simultaneous streams, and remove Keychain/cache data when a source is deleted.

## Secure AirPlay Relay

- Add an optional per-installation AirPlay relay configured in Settings. Users provide their own Cloudflare-managed base domain and a zone-scoped API token; store the token only in Keychain and never expose it in logs, persistence, crash text, or the app bundle.
- Generate a unique hostname such as `iptv-<random>.<domain>` for each installation. Discover the active private LAN IPv4 address automatically, create a DNS-only Cloudflare A record with an installation-specific ownership comment, update it when the LAN address changes, and delete only records created by the same installation. Do not depend on Cloudflare record tags because some zones have a tag quota of zero.
- Obtain and renew a publicly trusted certificate from Let's Encrypt using ACME DNS-01. Create short-lived `_acme-challenge` TXT records through Cloudflare, wait until an encrypted public DNS lookup returns the exact challenge value before notifying the CA, use the staging directory for validation before production issuance, retain private keys in Keychain, and remove challenge records on success, failure, and cancellation.
- Run a LAN-reachable HTTPS HLS reverse proxy on an ephemeral port. Give each playback session a cryptographically random path token, rewrite all playlist resource references to opaque relay URLs, preserve range requests and required content types, and cap response sizes and cache lifetime.
- Create an AirPlay-compatible rolling rendition when FFmpeg is available: copy the first H.264 video stream without re-encoding, detect non-H.264 input from private FFmpeg stream metadata, and automatically restart those inputs through VideoToolbox as H.264 at no more than 1080p. Convert the first audio stream to 48 kHz stereo AAC and force four-second keyframes for converted video. Publish hardware-converted video after three complete segments so detection plus conversion stays inside the preparation deadline, while copied video retains a six-segment handoff buffer; continue growing both rolling buffers after publication.
- Give FFmpeg only an opaque local relay URL, never the credential-bearing provider URL. Discover a bundled auxiliary executable first and development Homebrew locations second; redact process errors and fail back to direct native playback with an actionable notice when conversion is unavailable.
- For continuous raw MPEG-TS (`.ts`) sources, stream provider bytes through a bounded, backpressured, SSRF-checked HTTP client into FFmpeg standard input. Keep credential-bearing provider URLs out of FFmpeg arguments and publish the same H.264/AAC rolling rendition used for HLS inputs.
- Pace relay and raw MPEG-TS ingestion at source timestamps so the generated live edge cannot run ahead of wall time. Publish converted output as an Apple-compatible multivariant live presentation: a master playlist with peak/average bandwidth, exact frame rate, codec, and resolution attributes plus a media playlist containing at least six complete segments.
- Normalize every receiver-facing media-playlist refresh to a stable 12-second target duration, canonical RFC 3339 program date-times, canonical tag order, and no obsolete cache tag. Deliver full master and media playlists with negotiated gzip encoding, exact encoded lengths, and the recommended HLS MIME type; keep segments and byte ranges identity-encoded.
- Feed AVPlayer the relay manifest URL when the relay is ready so AirPlay hands the Apple TV a trusted hostname that resolves to the Mac's LAN address. Fall back to direct local playback if relay setup fails, and show an actionable, credential-free status.

## Verification

- Unit-test M3U parsing, Unicode and quoted attributes, malformed input, relative URLs, stable identity, URL redaction, gzip/XMLTV parsing, timezone boundaries, and now/next selection.
- Test encrypted snapshot round trips, Keychain lifecycle, conditional refresh, stale-cache fallback, reconciliation that preserves favorites, and recent-channel limits.
- Test playback-state mapping with local synthetic H.264/AAC HLS and MPEG-TS fixtures plus offline and unsupported-media failures.
- Test transcoder executable discovery, non-H.264 detection and VideoToolbox fallback, real-time input pacing, command construction, startup/timeout/termination cleanup, playlist normalization, gzip negotiation, strict generated-file routing, byte ranges, and traversal rejection. Manually verify both an H.264/MP2 source and a 4K/50 HEVC Main 10 source are exposed to AVPlayer and Apple TV as H.264/AAC with a live edge aligned to wall time.
- UI-test first-run setup, multiple-source management, groups, search, favorites, recents, resizing, light/dark mode, keyboard navigation, and accessibility labels.
- Manually validate the supplied feed without storing its URL in the repository, then verify video/audio AirPlay on an Apple TV and audio routing to an AirPlay speaker.
- Gate live Cloudflare/ACME integration coverage behind an ignored local marker and environment file. Verify zone access, DNS-only A/TXT creation, public TXT propagation, Let's Encrypt staging issuance, P-256 Security identity import, local TLS listener startup, and record cleanup without printing secrets.

## Explicit v1 Boundaries

- Catch-up/timeshift, recording, downloads, a timeline guide grid, reminders, local-file import, iCloud sync, and App Store submission remain out of scope.
- AirPlay remains dependent on the receiver reaching the Mac and supporting the generated H.264/AAC rendition. The compatibility rendition is capped at 1080p; 4K relay output and codecs unavailable to FFmpeg/VideoToolbox remain out of scope.
- Signing team and certificate selection stay in local Xcode settings and are not committed.
