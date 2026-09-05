import Foundation
import XCTest
@testable import ChannelDeck

/// Opt-in integration coverage. Normal test runs skip this test; invoke it
/// with CHANNELDECK_RUN_LIVE_CF_TEST=1 and Cloudflare values in the process
/// environment. Secrets are never interpolated into assertions or output.
final class LiveRelayProvisioningTests: XCTestCase {
    func testConfiguredRawStreamPreparesReceiverPlaylistWithinDeadline() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fileConfiguration = try Self.liveStreamFileConfiguration()
        guard environment["CHANNELDECK_RUN_LIVE_STREAM_TEST"] == "1"
                || fileConfiguration != nil else {
            throw XCTSkip("Live configured-stream preparation is opt-in.")
        }
        let playlistID = try XCTUnwrap(
            environment["CHANNELDECK_LIVE_PLAYLIST_ID"].flatMap(UUID.init(uuidString:))
                ?? fileConfiguration?.playlistID
        )
        let channelName = try XCTUnwrap(
            environment["CHANNELDECK_LIVE_CHANNEL_NAME"] ?? fileConfiguration?.channelName
        )
        let keychain = KeychainStore()
        let storedPlaylistURL = try await keychain.playlistURL(for: playlistID)
        let playlistURL = try XCTUnwrap(storedPlaylistURL)
        let fetchResult = try await HTTPClient().fetch(playlistURL, policy: .playlist)
        let playlistData: Data
        switch fetchResult {
        case let .modified(payload):
            playlistData = payload.data
        case .notModified:
            XCTFail("Unexpected not-modified response without validators")
            return
        }
        let playlist = try M3UParser().parse(data: playlistData, baseURL: playlistURL)
        let sourceURL = try XCTUnwrap(
            playlist.channels.first(where: { $0.name == channelName })?.streamURL
        )
        XCTAssertTrue(
            sourceURL.pathExtension.isEmpty
                || sourceURL.pathExtension.caseInsensitiveCompare("ts") == .orderedSame
        )

        let core = HLSRelayCore(upstream: LiveStaticHLSFetcher())
        let coordinator = HLSRelaySessionCoordinator(
            core: core,
            audioTranscoder: FFmpegHLSAudioTranscoder(),
            mpegTSStreamer: AsyncHTTPClientMPEGTSStreamSource(),
            preparationTimeout: .seconds(45)
        )
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let descriptor = try await coordinator.prepare(
                sourceURL: sourceURL,
                relayOrigin: URL(string: "https://relay.example:8443")!
            )
            let elapsed = start.duration(to: clock.now)
            XCTAssertLessThan(elapsed, .seconds(45))
            XCTAssertTrue(descriptor.playlistURL.path.hasSuffix("/transcoded/index.m3u8"))
            let master = try await core.handle(
                HLSRelayRequest(
                    method: .get,
                    path: descriptor.playlistURL.path,
                    range: nil,
                    ifNoneMatch: nil,
                    ifModifiedSince: nil
                )
            )
            XCTAssertEqual(master.statusCode, 200)
            XCTAssertTrue(String(decoding: master.body, as: UTF8.self).contains("media-0.m3u8"))
            await coordinator.stop()
        } catch {
            await coordinator.stop()
            throw error
        }
    }

    private struct LiveStreamFileConfiguration: Decodable {
        let playlistID: UUID
        let channelName: String
    }

    private static func liveStreamFileConfiguration() throws -> LiveStreamFileConfiguration? {
        let url = URL(fileURLWithPath: "/private/tmp/ChannelDeckLiveStreamTest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(
            LiveStreamFileConfiguration.self,
            from: Data(contentsOf: url)
        )
    }

    func testCloudflareDNS01AndTLSListener() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let markerURL = projectRoot.appendingPathComponent(".run-live-cloudflare-test")
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip("Live Cloudflare provisioning is opt-in.")
        }

        var configurationValues = ProcessInfo.processInfo.environment
        let dotEnvURL = projectRoot.appendingPathComponent(".env")
        if let dotEnv = try? String(contentsOf: dotEnvURL, encoding: .utf8) {
            for line in dotEnv.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                      let separator = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
                var value = String(trimmed[trimmed.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                if value.count >= 2,
                   (value.hasPrefix("\"") && value.hasSuffix("\"")
                    || value.hasPrefix("'") && value.hasSuffix("'")) {
                    value.removeFirst()
                    value.removeLast()
                }
                if configurationValues[key] == nil { configurationValues[key] = value }
            }
        }

        let markerDomain = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = try XCTUnwrap(configurationValues["CF_API_TOKEN"])
        let domain = try XCTUnwrap(configurationValues["CF_ZONE_DOMAIN"] ?? markerDomain)
        let accountID = configurationValues["CF_ACCOUNT_ID"]
        let installationID = UUID()
        let suffix = installationID.uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
        let hostname = "iptv-live-test-\(suffix).\(domain)"

        let configuration = try CloudflareDNSConfiguration(
            zoneDomain: domain,
            accountID: accountID,
            installationID: installationID
        )
        let tokenProvider = LiveTokenProvider(token: token)
        let dnsClient = CloudflareDNSClient(
            configuration: configuration,
            tokenProvider: tokenProvider
        )
        _ = try await dnsClient.verifyConfiguration()

        let lanAddress = try SystemLANAddressResolver().privateIPv4Address()
        let aRecord = try await dnsClient.upsertPrivateARecord(
            name: hostname,
            ipv4Address: lanAddress
        )

        do {
            let acmeConfiguration = ACMEConfiguration(
                directory: .letsEncryptStaging,
                contactEmail: nil,
                dnsPropagationDelay: 15,
                pollingInterval: 3,
                operationTimeout: 5 * 60,
                renewalThreshold: 30 * 24 * 60 * 60
            )
            let materialStore = LiveMaterialStore()
            let acmeClient = AcmeSwiftClientAdapter(
                configuration: acmeConfiguration,
                accountStore: materialStore
            )
            let manager = ACMECertificateManager(
                configuration: acmeConfiguration,
                client: acmeClient,
                dnsProvider: dnsClient,
                certificateStore: materialStore
            )
            let certificate: IssuedCertificateMaterial
            do {
                certificate = try await manager.ensureCertificate(for: hostname)
            } catch {
                if let diagnosis = await acmeClient.failureDiagnosis() {
                    XCTFail("Secret-free ACME diagnosis: \(diagnosis)")
                }
                throw error
            }
            XCTAssertEqual(certificate.hostname, hostname.lowercased())
            XCTAssertGreaterThan(certificate.notAfter, Date())

            let storedIdentity = try await materialStore.loadIdentity()
            let identity = try XCTUnwrap(storedIdentity)
            let relay = HLSRelayServer(
                identity: HLSRelayTLSIdentity(identity.protocolIdentity),
                advertisedHost: hostname,
                upstream: LiveStaticHLSFetcher()
            )
            let descriptor = try await relay.relayURL(
                for: URL(string: "https://upstream.example.invalid/live/index.m3u8")!
            )
            XCTAssertEqual(descriptor.playlistURL.scheme, "https")
            XCTAssertEqual(descriptor.playlistURL.host, hostname.lowercased())
            await relay.stop()
        } catch {
            try? await dnsClient.deleteOwnedRecord(recordID: aRecord.id)
            throw error
        }

        try await dnsClient.deleteOwnedRecord(recordID: aRecord.id)
    }
}

private struct LiveTokenProvider: CloudflareAPITokenProviding {
    let token: String

    func apiToken() -> String? { token }
}

private actor LiveMaterialStore: ACMEAccountCredentialStoring, RelayCertificateStoring {
    private var accounts: [String: Data] = [:]
    private var certificate: IssuedCertificateMaterial?

    func accountCredentials(for directoryIdentifier: String) -> Data? {
        accounts[directoryIdentifier]
    }

    func saveAccountCredentials(_ data: Data, for directoryIdentifier: String) {
        accounts[directoryIdentifier] = data
    }

    func loadCertificate() -> IssuedCertificateMaterial? { certificate }

    func saveCertificate(_ certificate: IssuedCertificateMaterial) {
        self.certificate = certificate
    }

    func removeCertificate() {
        certificate = nil
    }

    func loadIdentity() throws -> RelayTLSIdentity? {
        guard let certificate else { return nil }
        return try RelayTLSIdentityFactory.makeIdentity(from: certificate)
    }
}

private struct LiveStaticHLSFetcher: HLSRelayUpstreamFetching {
    func fetch(_ request: HLSRelayUpstreamRequest) -> HLSRelayUpstreamResponse {
        HLSRelayUpstreamResponse(
            statusCode: 200,
            body: Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4,\nsegment.ts\n".utf8),
            finalURL: request.url,
            contentType: "application/vnd.apple.mpegurl"
        )
    }
}
