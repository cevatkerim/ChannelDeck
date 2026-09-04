import Foundation
import Observation

enum AirPlayRelayPhase: Equatable, Sendable {
    case notConfigured
    case checkingNetwork
    case checkingCloudflare
    case updatingDNS
    case requestingCertificate
    case startingRelay
    case resetting
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .notConfigured: "Not configured"
        case .checkingNetwork: "Detecting local network…"
        case .checkingCloudflare: "Checking Cloudflare access…"
        case .updatingDNS: "Updating private DNS record…"
        case .requestingCertificate: "Requesting certificate…"
        case .startingRelay: "Starting secure relay…"
        case .resetting: "Removing relay configuration…"
        case .ready: "Ready for AirPlay"
        case .failed: "Setup needs attention"
        }
    }

    var isBusy: Bool {
        switch self {
        case .checkingNetwork, .checkingCloudflare, .updatingDNS,
             .requestingCertificate, .startingRelay, .resetting:
            true
        default:
            false
        }
    }
}

@MainActor
@Observable
final class AirPlayRelayController {
    var zoneDomain: String
    var accountID: String
    var apiTokenInput = ""
    var certificateEnvironment: AirPlayRelayCertificateEnvironment

    private(set) var phase: AirPlayRelayPhase
    private(set) var detectedLANAddress: String?
    private(set) var hasStoredToken = false
    private(set) var certificateExpiration: Date?
    private(set) var playbackNotice: String?
    private(set) var playbackIsRelayed = false

    var hostname: String {
        let zone = zoneDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return zone.isEmpty ? "\(preferences.hostLabel).your-domain.example" : "\(preferences.hostLabel).\(zone)"
    }

    var canConfigure: Bool {
        !phase.isBusy
            && !zoneDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (hasStoredToken || !apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var isReady: Bool { phase == .ready }

    @ObservationIgnored private let keychain: any KeychainStoring
    @ObservationIgnored private let preferencesStore: AirPlayRelayPreferencesStore
    @ObservationIgnored private let addressResolver: any LANAddressResolving
    @ObservationIgnored private var preferences: AirPlayRelayPreferences
    @ObservationIgnored private var relayServer: HLSRelayServer?
    @ObservationIgnored private var operationIsActive = false

    init(
        keychain: any KeychainStoring,
        preferencesStore: AirPlayRelayPreferencesStore = AirPlayRelayPreferencesStore(),
        addressResolver: any LANAddressResolving = SystemLANAddressResolver()
    ) {
        self.keychain = keychain
        self.preferencesStore = preferencesStore
        self.addressResolver = addressResolver
        let preferences = preferencesStore.loadOrCreate()
        self.preferences = preferences
        zoneDomain = preferences.zoneDomain
        accountID = preferences.accountID
        certificateEnvironment = preferences.certificateEnvironment
        phase = .notConfigured
    }

    func bootstrap() async {
        guard beginOperation(with: .checkingNetwork) else { return }
        defer { operationIsActive = false }

        detectedLANAddress = try? addressResolver.privateIPv4Address()
        let tokenStore = KeychainCloudflareTokenStore(
            keychain: keychain,
            installationID: preferences.installationID
        )
        hasStoredToken = (try? await tokenStore.apiToken()) != nil
        let store = certificateStore(for: certificateEnvironment)
        certificateExpiration = try? await store.loadCertificate()?.notAfter

        guard preferences.hostname != nil, hasStoredToken else {
            phase = .notConfigured
            return
        }
        await configureWhileLocked()
    }

    func configure() async {
        guard beginOperation(with: .checkingNetwork) else { return }
        defer { operationIsActive = false }
        await configureWhileLocked()
    }

    private func configureWhileLocked() async {
        playbackNotice = nil

        let previousPreferences = preferences
        let cloudflareConfiguration: CloudflareDNSConfiguration
        do {
            cloudflareConfiguration = try CloudflareDNSConfiguration(
                zoneDomain: zoneDomain,
                accountID: normalizedAccountID,
                installationID: preferences.installationID
            )
        } catch {
            phase = .failed(safeMessage(for: error))
            return
        }

        let tokenStore = KeychainCloudflareTokenStore(
            keychain: keychain,
            installationID: preferences.installationID
        )
        var provisionalRecord: CloudflareDNSRecord?
        var provisionalDNSClient: CloudflareDNSClient?
        var provisionalServer: HLSRelayServer?
        do {
            let storedToken = try await tokenStore.apiToken()
            let enteredToken = apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let desiredToken = enteredToken.isEmpty ? storedToken : enteredToken else {
                throw CloudflareDNSClientError.missingAPIToken
            }
            let desiredHostname = "\(preferences.hostLabel).\(cloudflareConfiguration.zoneDomain)"
            let desiredTokenProvider = EphemeralCloudflareTokenProvider(token: desiredToken)

            phase = .checkingNetwork
            let lanAddress = try addressResolver.privateIPv4Address()
            detectedLANAddress = lanAddress

            let dnsClient = CloudflareDNSClient(
                configuration: cloudflareConfiguration,
                tokenProvider: desiredTokenProvider
            )
            provisionalDNSClient = dnsClient
            phase = .checkingCloudflare
            _ = try await dnsClient.verifyConfiguration()

            phase = .updatingDNS
            let aRecord = try await dnsClient.upsertPrivateARecord(
                name: desiredHostname,
                ipv4Address: lanAddress
            )
            provisionalRecord = aRecord

            phase = .requestingCertificate
            let acmeConfiguration: ACMEConfiguration = certificateEnvironment == .production
                ? .production
                : .staging
            let materialStore = certificateStore(for: certificateEnvironment)
            let acmeClient = AcmeSwiftClientAdapter(
                configuration: acmeConfiguration,
                accountStore: materialStore
            )
            let certificateManager = ACMECertificateManager(
                configuration: acmeConfiguration,
                client: acmeClient,
                dnsProvider: dnsClient,
                certificateStore: materialStore
            )
            let certificate = try await certificateManager.ensureCertificate(for: desiredHostname)
            guard let identity = try await materialStore.loadIdentity() else {
                throw ACMECertificateError.identityUnavailable
            }

            phase = .startingRelay
            let server = HLSRelayServer(
                identity: HLSRelayTLSIdentity(identity.protocolIdentity),
                advertisedHost: desiredHostname,
                upstream: AsyncHTTPClientHLSRelayUpstreamFetcher(),
                audioTranscoder: FFmpegHLSAudioTranscoder(),
                mpegTSStreamer: AsyncHTTPClientMPEGTSStreamSource()
            )
            provisionalServer = server
            try await server.start()

            // Do not replace the old token or preferences until the new DNS,
            // certificate, and listener are all known-good.
            try await tokenStore.store(desiredToken)
            let zoneChanged = !previousPreferences.zoneDomain.isEmpty
                && previousPreferences.zoneDomain.caseInsensitiveCompare(cloudflareConfiguration.zoneDomain) != .orderedSame
            if zoneChanged, let oldRecordID = previousPreferences.dnsARecordID {
                guard let oldToken = storedToken else {
                    throw CloudflareDNSClientError.credentialUnavailable
                }
                do {
                    let oldConfiguration = try CloudflareDNSConfiguration(
                        zoneDomain: previousPreferences.zoneDomain,
                        accountID: previousPreferences.accountID.isEmpty ? nil : previousPreferences.accountID,
                        installationID: previousPreferences.installationID
                    )
                    let oldClient = CloudflareDNSClient(
                        configuration: oldConfiguration,
                        tokenProvider: EphemeralCloudflareTokenProvider(token: oldToken)
                    )
                    do {
                        try await oldClient.deleteOwnedRecord(recordID: oldRecordID)
                    } catch CloudflareDNSClientError.recordNotFound {
                        // The old zone already has the desired clean state.
                    }
                } catch {
                    try? await tokenStore.store(oldToken)
                    throw error
                }
            }

            var committed = previousPreferences
            committed.zoneDomain = cloudflareConfiguration.zoneDomain
            committed.accountID = normalizedAccountID ?? ""
            committed.certificateEnvironment = certificateEnvironment
            committed.dnsARecordID = aRecord.id
            preferences = committed
            preferencesStore.save(committed)
            zoneDomain = committed.zoneDomain
            accountID = committed.accountID
            apiTokenInput = ""
            hasStoredToken = true
            certificateExpiration = certificate.notAfter

            let oldServer = relayServer
            relayServer = server
            provisionalServer = nil
            if let oldServer { await oldServer.stop() }
            phase = .ready
        } catch is CancellationError {
            if let provisionalServer { await provisionalServer.stop() }
            await rollbackProvisionalRecord(
                provisionalRecord,
                using: provisionalDNSClient,
                previousRecordID: previousPreferences.dnsARecordID
            )
            phase = .failed("Relay setup was cancelled.")
        } catch {
            if let provisionalServer { await provisionalServer.stop() }
            await rollbackProvisionalRecord(
                provisionalRecord,
                using: provisionalDNSClient,
                previousRecordID: previousPreferences.dnsARecordID
            )
            phase = .failed(safeMessage(for: error))
        }
    }

    /// Returns the receiver-reachable URL when the relay is ready. Unsupported
    /// sources safely fall back to direct native playback on this Mac.
    func playbackURL(for sourceURL: URL) async -> URL {
        guard phase == .ready, let relayServer else {
            playbackNotice = nil
            playbackIsRelayed = false
            return sourceURL
        }
        playbackNotice = "Preparing AirPlay-compatible audio…"
        playbackIsRelayed = true
        do {
            let session = try await relayServer.relayURL(for: sourceURL)
            try Task.checkCancellation()
            playbackNotice = "Secure AirPlay relay active · AAC audio"
            playbackIsRelayed = true
            return session.playlistURL
        } catch is CancellationError {
            playbackNotice = nil
            playbackIsRelayed = false
            return sourceURL
        } catch let error as FFmpegHLSAudioTranscoderError {
            playbackNotice = "\(error.localizedDescription) Playing directly on this Mac."
            playbackIsRelayed = false
            return sourceURL
        } catch let error as HLSRelayError {
            playbackNotice = "\(error.localizedDescription) Playing directly on this Mac."
            playbackIsRelayed = false
            return sourceURL
        } catch {
            playbackNotice = "Secure relay unavailable for this channel. Playing directly on this Mac."
            playbackIsRelayed = false
            return sourceURL
        }
    }

    func refreshLANAddress() {
        do {
            detectedLANAddress = try addressResolver.privateIPv4Address()
        } catch {
            detectedLANAddress = nil
            if preferences.hostname != nil {
                phase = .failed(safeMessage(for: error))
            }
        }
    }

    func reset() async {
        guard beginOperation(with: .resetting) else { return }
        defer { operationIsActive = false }

        let configurationToRemove = preferences
        let hostnameToRemove = preferences.hostname
        let tokenStore = KeychainCloudflareTokenStore(
            keychain: keychain,
            installationID: preferences.installationID
        )
        let serverToStop = relayServer
        relayServer = nil
        if let serverToStop { await serverToStop.stop() }

        var remoteDNSRemovalFailed = false
        var secureStorageRemovalFailed = false
        if let recordID = configurationToRemove.dnsARecordID, hostnameToRemove != nil {
            if (try? await tokenStore.apiToken()) == nil {
                remoteDNSRemovalFailed = true
            } else if let configuration = try? CloudflareDNSConfiguration(
                zoneDomain: configurationToRemove.zoneDomain,
                accountID: configurationToRemove.accountID.isEmpty ? nil : configurationToRemove.accountID,
                installationID: configurationToRemove.installationID
            ) {
                let client = CloudflareDNSClient(configuration: configuration, tokenProvider: tokenStore)
                do {
                    try await client.deleteOwnedRecord(recordID: recordID)
                } catch CloudflareDNSClientError.recordNotFound {
                    // The desired clean state already exists.
                } catch {
                    remoteDNSRemovalFailed = true
                }
            } else {
                remoteDNSRemovalFailed = true
            }
        }

        do {
            try await certificateStore(for: .staging).removeCertificate()
        } catch {
            secureStorageRemovalFailed = true
        }
        do {
            try await certificateStore(for: .production).removeCertificate()
        } catch {
            secureStorageRemovalFailed = true
        }
        do {
            try await tokenStore.remove()
        } catch {
            secureStorageRemovalFailed = true
        }

        preferences = preferencesStore.clearConfiguration()
        zoneDomain = ""
        accountID = ""
        apiTokenInput = ""
        certificateEnvironment = .production
        hasStoredToken = (try? await tokenStore.apiToken()) != nil
        certificateExpiration = nil
        playbackNotice = nil
        playbackIsRelayed = false

        if secureStorageRemovalFailed {
            phase = .failed("The relay stopped, but some Keychain items could not be removed.")
        } else if remoteDNSRemovalFailed, let hostnameToRemove {
            phase = .failed("The relay stopped. Remove \(hostnameToRemove) from Cloudflare DNS manually.")
        } else {
            phase = .notConfigured
        }
    }

    private func rollbackProvisionalRecord(
        _ record: CloudflareDNSRecord?,
        using client: CloudflareDNSClient?,
        previousRecordID: String?
    ) async {
        guard let record, record.id != previousRecordID, let client else { return }
        try? await client.deleteOwnedRecord(recordID: record.id)
    }

    private func beginOperation(with phase: AirPlayRelayPhase) -> Bool {
        guard !operationIsActive else { return false }
        operationIsActive = true
        self.phase = phase
        return true
    }

    private var normalizedAccountID: String? {
        let value = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func certificateStore(
        for environment: AirPlayRelayCertificateEnvironment
    ) -> ACMEKeychainMaterialStore {
        ACMEKeychainMaterialStore(
            service: "com.kerimincedayi.ChannelDeck.acme-material.\(environment.rawValue)"
        )
    }

    private func safeMessage(for error: Error) -> String {
        if let error = error as? LocalizedError,
           let message = error.errorDescription,
           !message.isEmpty {
            return message
        }
        return "Secure AirPlay relay setup could not be completed."
    }
}

private struct EphemeralCloudflareTokenProvider: CloudflareAPITokenProviding {
    let token: String

    func apiToken() -> String? { token }
}
