@preconcurrency import AcmeSwift
@preconcurrency import AsyncHTTPClient
import Foundation
@preconcurrency import Logging
import X509

/// Concrete RFC 8555 implementation backed by AcmeSwift 1.0.0. The dependency
/// handles nonce/JWS/account operations and creates a P-256 PKCS#10 CSR whose
/// SAN exactly contains the requested relay hostname.
actor AcmeSwiftClientAdapter: ACMEClientProtocol {
    private enum FailureStage: String {
        case directory
        case account
        case order
        case challengeDescription
        case challengeValidation
        case orderRefresh
        case finalization
        case certificateDownload
    }

    private struct OrderState: Sendable {
        var order: AcmeOrderInfo
        let hostname: String
        var validationRequested = false
    }

    private let configuration: ACMEConfiguration
    private let accountStore: any ACMEAccountCredentialStoring
    private var client: AcmeSwift?
    private var httpClient: AsyncHTTPClient.HTTPClient?
    private var orders: [String: OrderState] = [:]
    private var lastFailure: String?

    init(
        configuration: ACMEConfiguration,
        accountStore: any ACMEAccountCredentialStoring
    ) {
        self.configuration = configuration
        self.accountStore = accountStore
    }

    func prepareOrder(hostname: String) async throws -> ACMEPreparedOrder {
        let hostname = try ACMEHostname.normalized(hostname)
        let client = try await configuredClient()
        let order: AcmeOrderInfo
        do {
            order = try await client.orders.create(domains: [hostname])
        } catch {
            recordFailure(error, at: .order)
            throw error
        }
        let descriptions: [ChallengeDescription]
        do {
            descriptions = try await client.orders.describePendingChallenges(
                from: order,
                preferring: .dns
            )
        } catch {
            recordFailure(error, at: .challengeDescription)
            throw error
        }
        let dnsChallenges = descriptions
            .filter { $0.type == .dns }
            .enumerated()
            .map { index, challenge in
                ACMEDNSChallenge(
                    id: "dns-\(index)",
                    recordName: challenge.endpoint,
                    value: challenge.value
                )
            }

        let orderID = UUID().uuidString.lowercased()
        orders[orderID] = OrderState(order: order, hostname: hostname)
        return ACMEPreparedOrder(id: orderID, challenges: dnsChallenges)
    }

    func validateDNSChallenges(orderID: String) async throws -> ACMEValidationResult {
        guard var state = orders[orderID] else {
            throw ACMECertificateError.issuanceFailed
        }
        let client = try await configuredClient()
        if !state.validationRequested {
            let challenges: [AcmeAuthorization.Challenge]
            do {
                challenges = try await client.orders.validateChallenges(
                    from: state.order,
                    preferring: .dns
                )
            } catch {
                recordFailure(error, at: .challengeValidation)
                throw error
            }
            state.validationRequested = true
            if let invalidChallenge = challenges.first(where: { $0.status == .invalid }) {
                if let response = invalidChallenge.error {
                    recordFailure(response, at: .challengeValidation)
                } else {
                    lastFailure = "\(FailureStage.challengeValidation.rawValue):invalid"
                }
                orders[orderID] = state
                return ACMEValidationResult(state: .invalid, retryAfter: nil)
            }
        }

        do {
            try await client.orders.refresh(&state.order)
        } catch {
            recordFailure(error, at: .orderRefresh)
            throw error
        }
        orders[orderID] = state

        switch state.order.status {
        case .ready, .valid:
            return ACMEValidationResult(state: .valid, retryAfter: nil)
        case .invalid:
            if let authorizations = try? await client.orders.getAuthorizations(from: state.order),
               let response = authorizations
                .flatMap(\.challenges)
                .first(where: { $0.status == .invalid })?
                .error {
                recordFailure(response, at: .challengeValidation)
            } else {
                lastFailure = "\(FailureStage.orderRefresh.rawValue):invalid"
            }
            return ACMEValidationResult(state: .invalid, retryAfter: nil)
        case .pending, .processing:
            return ACMEValidationResult(state: .pending, retryAfter: nil)
        }
    }

    func finalizeOrder(orderID: String) async throws -> IssuedCertificateMaterial {
        guard var state = orders[orderID] else {
            throw ACMECertificateError.issuanceFailed
        }
        let client = try await configuredClient()
        let privateKey: Certificate.PrivateKey
        do {
            privateKey = try await client.orders.finalize(
                order: &state.order,
                type: .ecdsa(.p256)
            )
        } catch {
            recordFailure(error, at: .finalization)
            throw error
        }
        orders[orderID] = state

        let certificates: [String]
        do {
            certificates = try await client.certificates.download(for: state.order)
        } catch {
            recordFailure(error, at: .certificateDownload)
            throw error
        }
        guard let leaf = certificates.first else {
            throw ACMECertificateError.invalidCertificateMaterial
        }
        let privateKeyPEM = try privateKey.serializeAsPEM().pemString
        let expiration = try RelayTLSIdentityFactory.certificateExpiration(fromPEM: leaf)
        let material = IssuedCertificateMaterial(
            hostname: state.hostname,
            privateKeyPEM: privateKeyPEM,
            certificateChainPEM: certificates,
            issuedAt: .now,
            notAfter: expiration
        )
        orders.removeValue(forKey: orderID)
        return material
    }

    func shutdown() async {
        guard let httpClient else {
            client = nil
            orders.removeAll()
            return
        }
        _ = try? await httpClient.shutdown().get()
        client = nil
        self.httpClient = nil
        orders.removeAll()
    }

    /// A secret-free stage and error category intended for diagnostics and UI
    /// support. Associated server text and request bodies are never retained.
    func failureDiagnosis() -> String? { lastFailure }

    private func configuredClient() async throws -> AcmeSwift {
        if let client { return client }
        guard configuration.directory.isSecure else {
            throw ACMECertificateError.invalidConfiguration
        }

        // AcmeSwift emits full JWS request bodies at debug level. This dedicated
        // logger permanently suppresses every message below critical.
        var logger = Logger(label: "com.kerimincedayi.ChannelDeck.acme.redacted")
        logger.logLevel = .critical
        let httpClient = AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .createNew)
        let configuredClient: AcmeSwift
        do {
            configuredClient = try await AcmeSwift(
                client: httpClient,
                acmeEndpoint: endpoint(configuration.directory),
                logger: logger
            )
        } catch {
            recordFailure(error, at: .directory)
            _ = try? await httpClient.shutdown().get()
            throw error
        }

        do {
            let storageID = configuration.directory.storageIdentifier
            if let stored = try await accountStore.accountCredentials(for: storageID) {
                let account = try JSONDecoder().decode(AcmeAccountInfo.self, from: stored)
                try configuredClient.account.use(account)
            } else {
                let contacts = sanitizedContacts(configuration.contactEmail)
                let account = try await configuredClient.account.create(contacts: contacts, acceptTOS: true)
                let encoded = try JSONEncoder().encode(account)
                try await accountStore.saveAccountCredentials(encoded, for: storageID)
                try configuredClient.account.use(account)
            }

            self.httpClient = httpClient
            client = configuredClient
            return configuredClient
        } catch {
            recordFailure(error, at: .account)
            _ = try? await httpClient.shutdown().get()
            throw error
        }
    }

    private func recordFailure(_ error: Error, at stage: FailureStage) {
        let category: String
        if let response = error as? AcmeResponseError {
            category = response.type.rawValue
        } else if let acmeError = error as? AcmeError {
            switch acmeError {
            case .invalidAccountInfo: category = "invalidAccountInfo"
            case .mustBeAuthenticated: category = "mustBeAuthenticated"
            case .deactivateFailed: category = "deactivateFailed"
            case .certificateNotReady: category = "certificateNotReady"
            case .noNonceReturned: category = "noNonceReturned"
            case .noIssuerDomainReturned: category = "noIssuerDomainReturned"
            case .dataCorrupted: category = "dataCorrupted"
            case let .errorCode(status, _): category = "http-\(status)"
            case .noResourceUrl: category = "noResourceUrl"
            case .noDomains: category = "noDomains"
            case .unsupportedChallenge: category = "unsupportedChallenge"
            case .missingChallengeToken: category = "missingChallengeToken"
            }
        } else {
            category = String(reflecting: type(of: error))
        }
        lastFailure = "\(stage.rawValue):\(category)"
    }

    private func endpoint(_ directory: ACMEDirectoryEndpoint) -> AcmeEndpoint {
        switch directory {
        case .letsEncryptStaging: .letsEncryptStaging
        case .letsEncryptProduction: .letsEncrypt
        case let .custom(url): .custom(url)
        }
    }

    private func sanitizedContacts(_ email: String?) -> [String] {
        guard let email else { return [] }
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 254,
              value.contains("@"),
              !value.contains("\r"),
              !value.contains("\n") else {
            return []
        }
        return [value]
    }
}
