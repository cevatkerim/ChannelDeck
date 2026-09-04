import Foundation
import XCTest
@testable import ChannelDeck

/// Opt-in integration coverage. Normal test runs skip this test; invoke it
/// with CHANNELDECK_RUN_LIVE_CF_TEST=1 and Cloudflare values in the process
/// environment. Secrets are never interpolated into assertions or output.
final class LiveRelayProvisioningTests: XCTestCase {
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
