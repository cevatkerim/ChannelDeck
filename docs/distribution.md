# Building and distributing ChannelDeck

The first distribution target is an Apple Silicon (`arm64`) Mac running macOS 15 or newer. A self-contained DMG contains ChannelDeck and an Applications shortcut. FFmpeg is bundled with the app; the recipient does not need Homebrew, Xcode, or a separate media-tool installation.

This workflow produces a testing build without a Developer ID certificate or Apple notarization. Its local ad hoc signature supports bundle integrity checks but does not identify an Apple-verified developer. Describe it as an **ad hoc-signed, unnotarized testing build without Developer ID signing** wherever it is shared.

## Install the test build

1. Obtain the DMG and its checksum from the person or release page distributing the build.
2. Quit any older running copy, open `ChannelDeck-0.2.1-arm64.dmg`, and drag **ChannelDeck** into **Applications**.
3. Eject the disk image and open ChannelDeck from Applications.
4. If macOS blocks the app and you trust its source, open **System Settings → Privacy & Security**, find the ChannelDeck notice under Security, and choose **Open Anyway**. Depending on the macOS version, an **Open** button may appear first. Confirm the prompt and authenticate if requested.

Apple makes this exception available for approximately an hour after an attempted launch. Consult [Apple's current instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac) if the wording differs. Organization-managed Macs may prohibit the exception; their administrator controls that policy.

No playlist, subscription, or account is supplied. Add your own authorized playlist after installation. The optional secure AirPlay relay still requires the setup described in the [README](../README.md#secure-airplay-relay).

## Build the artifacts

Use an Apple Silicon Mac with Xcode 16 or newer selected as the active developer directory. The first build needs network access to download pinned FFmpeg source and resolve Swift packages.

From the repository root:

```sh
bash Scripts/build_ffmpeg.sh
./Scripts/package_unsigned_dmg.sh
```

The FFmpeg recipe creates an LGPL build from pinned FFmpeg 8.0.1 source, without GPL or nonfree components. It uses Apple system frameworks rather than Homebrew libraries. The package workflow uses a separate `.release-build/DerivedData` directory so packaging does not replace an app running from the development build directory.

Expected outputs for version 0.2.1:

| Artifact | Purpose |
| --- | --- |
| `dist/ChannelDeck-0.2.1-arm64.dmg` | Drag-to-Applications installer |
| `dist/ChannelDeck-0.2.1-arm64.dmg.sha256` | DMG integrity checksum |
| `dist/ChannelDeck-0.2.1-ffmpeg-source.tar.gz` | Corresponding FFmpeg source, build recipe, and configuration |
| `dist/ChannelDeck-0.2.1-ffmpeg-source.tar.gz.sha256` | Source archive integrity checksum |
| `dist/ChannelDeck-0.2.1-arm64-NOTICES.txt` | Distribution notice and dependency licensing summary |

Dependency notices accompany the distribution. The packaging script refuses to overwrite an existing output; move an earlier artifact aside before making a new build. Generated binaries, downloaded source, and staging directories are local build products and should not be committed to Git.

To check a downloaded or copied DMG, place its checksum beside it and run:

```sh
cd dist
shasum -a 256 -c ChannelDeck-0.2.1-arm64.dmg.sha256
```

A matching checksum confirms the file matches the supplied checksum; it is not a substitute for a trusted download source or Developer ID signing.

## Verify before sharing

The package should pass signature-integrity and Mach-O dependency checks, and its bundled FFmpeg should run with no Homebrew libraries available. Gatekeeper acceptance is not expected for this testing build: an ad hoc signature is not a Developer ID signature.

Test the actual downloaded DMG on another Apple Silicon Mac with macOS 15 or newer and no development tools installed. Confirm installation, launch, playlist import, normal playback, live rewind, both recording modes, recording playback, and AirPlay where relay setup is available. A local build check alone does not establish that first-launch installation works on a clean Mac.

Publish the DMG, checksum, FFmpeg source archive, and dependency notices together if a release is created. The scripts only build local files; they do not publish a release or upload credentials, settings, playlists, or recordings.

## Dependency licenses and source

ChannelDeck's own code is available under [PolyForm Noncommercial 1.0.0](../LICENSE.md). FFmpeg and other dependencies retain their independent licenses; the application's noncommercial terms do not restrict rights granted by those licenses.

The bundled FFmpeg executable is licensed under LGPL 2.1 or later. Its corresponding source archive, build recipe, configuration, and license text must remain available with distributed binaries. The recipe's prepared files live under `.release-build/ffmpeg`: `NOTICE.txt`, `LICENSE.txt`, and `source/`. The source bundle includes the exact upstream archive used for the binary. License texts for FFmpeg and Swift package dependencies are also included in the DMG's `ThirdPartyNotices` folder and the app's `Contents/Resources/ThirdPartyNotices`. See [FFmpeg's license and distribution guidance](https://ffmpeg.org/legal.html).

Do not substitute a Homebrew FFmpeg executable into a release: it may depend on libraries absent from another Mac and enable components under different licenses.

## Later: Developer ID signing and notarization

After enrolling in the Apple Developer Program, the same app and dependency build can be used for a trusted distribution pipeline. Apple's [Developer ID overview](https://developer.apple.com/support/developer-id/) and [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) describe the requirements.

1. Install a **Developer ID Application** certificate and its private key on the signing Mac, or configure them in a protected release environment.
2. Sign bundled executables and frameworks first, then the app, using the Developer ID identity, a secure timestamp, and hardened runtime with only the entitlements the app needs.
3. Submit the app in a supported archive to Apple's notary service using `xcrun notarytool`. Review any failures, wait for acceptance, and staple the ticket to the app.
4. Create the DMG from the stapled app, sign the DMG, submit it for notarization, and staple the accepted ticket to the DMG.
5. Validate tickets and signatures, assess Gatekeeper acceptance, and repeat installation testing using the final download artifact.

Keep certificate private keys and notarization credentials in Keychain or protected release secrets. They are not repository files. These signing and notarization steps are a future release path, not capabilities supplied by the unsigned packaging script.
