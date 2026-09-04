import Foundation

protocol ACMEClientProtocol: Sendable {
    func prepareOrder(hostname: String) async throws -> ACMEPreparedOrder
    func validateDNSChallenges(orderID: String) async throws -> ACMEValidationResult
    func finalizeOrder(orderID: String) async throws -> IssuedCertificateMaterial
    func shutdown() async
}

extension ACMEClientProtocol {
    func shutdown() async {}
}

protocol DNSChallengeProviding: Sendable {
    func presentTXTRecord(name: String, value: String) async throws -> DNSChallengeRecord
    func removeTXTRecord(_ record: DNSChallengeRecord) async throws
}

enum DNSPropagationStatus: Equatable, Sendable {
    case visible
    case pending
}

/// Checks the public DNS view without receiving API credentials. Implementations
/// must compare the complete TXT value; observing the record name alone is not
/// sufficient for an ACME dns-01 challenge.
protocol DNSPropagationChecking: Sendable {
    func checkTXTRecord(name: String, value: String) async throws -> DNSPropagationStatus
}

protocol ACMEAccountCredentialStoring: Sendable {
    func accountCredentials(for directoryIdentifier: String) async throws -> Data?
    func saveAccountCredentials(_ data: Data, for directoryIdentifier: String) async throws
}

protocol RelayCertificateStoring: Sendable {
    func loadCertificate() async throws -> IssuedCertificateMaterial?
    func saveCertificate(_ certificate: IssuedCertificateMaterial) async throws
    func removeCertificate() async throws
    func loadIdentity() async throws -> RelayTLSIdentity?
}

protocol ACMEClock: Sendable {
    func now() async -> Date
    func sleep(for interval: TimeInterval) async throws
}

struct SystemACMEClock: ACMEClock {
    func now() -> Date { .now }

    func sleep(for interval: TimeInterval) async throws {
        guard interval > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: .seconds(interval))
    }
}
