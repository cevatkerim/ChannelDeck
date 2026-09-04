import Foundation
import CryptoKit

enum ACMEDirectoryEndpoint: Equatable, Sendable {
    case letsEncryptStaging
    case letsEncryptProduction
    case custom(URL)

    var url: URL {
        switch self {
        case .letsEncryptStaging:
            URL(string: "https://acme-staging-v02.api.letsencrypt.org/directory")!
        case .letsEncryptProduction:
            URL(string: "https://acme-v02.api.letsencrypt.org/directory")!
        case let .custom(url):
            url
        }
    }

    /// A non-secret storage namespace. Custom endpoint URLs are deliberately
    /// not embedded in Keychain account labels or diagnostics.
    var storageIdentifier: String {
        switch self {
        case .letsEncryptStaging: return "letsencrypt-staging"
        case .letsEncryptProduction: return "letsencrypt-production"
        case let .custom(url):
            let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            return "custom-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        }
    }

    var isSecure: Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
    }
}

struct ACMEConfiguration: Equatable, Sendable {
    var directory: ACMEDirectoryEndpoint
    var contactEmail: String?
    var dnsPropagationDelay: TimeInterval
    var pollingInterval: TimeInterval
    var operationTimeout: TimeInterval
    var renewalThreshold: TimeInterval

    static let staging = ACMEConfiguration(
        directory: .letsEncryptStaging,
        contactEmail: nil,
        dnsPropagationDelay: 15,
        pollingInterval: 5,
        operationTimeout: 5 * 60,
        renewalThreshold: 30 * 24 * 60 * 60
    )

    static let production = ACMEConfiguration(
        directory: .letsEncryptProduction,
        contactEmail: nil,
        dnsPropagationDelay: 15,
        pollingInterval: 5,
        operationTimeout: 5 * 60,
        renewalThreshold: 30 * 24 * 60 * 60
    )
}

struct ACMEDNSChallenge: Equatable, Sendable {
    let id: String
    let recordName: String
    let value: String
}

struct ACMEPreparedOrder: Equatable, Sendable {
    let id: String
    let challenges: [ACMEDNSChallenge]
}

enum ACMEValidationState: Equatable, Sendable {
    case pending
    case valid
    case invalid
}

struct ACMEValidationResult: Equatable, Sendable {
    let state: ACMEValidationState
    /// Delay requested by the ACME service. `nil` uses the configured default.
    let retryAfter: TimeInterval?
}

struct DNSChallengeRecord: Equatable, Sendable {
    let id: String
    let name: String
}

/// PEM material is kept as one Keychain value and never persisted to a file.
/// The custom descriptions prevent accidental interpolation from exposing it.
struct IssuedCertificateMaterial: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let hostname: String
    let privateKeyPEM: String
    let certificateChainPEM: [String]
    let issuedAt: Date
    let notAfter: Date

    var description: String { "<redacted relay certificate>" }
    var debugDescription: String { description }
}

struct CertificateRenewalPolicy: Equatable, Sendable {
    let threshold: TimeInterval

    func needsRenewal(
        _ certificate: IssuedCertificateMaterial?,
        hostname: String,
        now: Date
    ) -> Bool {
        guard let certificate,
              certificate.hostname.caseInsensitiveCompare(hostname) == .orderedSame else {
            return true
        }
        return certificate.notAfter <= now.addingTimeInterval(max(0, threshold))
    }
}

enum ACMECertificateError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidHostname
    case noDNSChallenge
    case challengeRejected
    case challengeTimedOut
    case dnsUpdateFailed
    case dnsCleanupFailed
    case issuanceFailed
    case secureStorageFailed
    case invalidCertificateMaterial
    case identityUnavailable
}

extension ACMECertificateError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Certificate service configuration is invalid."
        case .invalidHostname:
            "The generated relay hostname is invalid."
        case .noDNSChallenge:
            "The certificate service did not provide a DNS challenge."
        case .challengeRejected:
            "The certificate service rejected domain validation."
        case .challengeTimedOut:
            "Domain validation timed out."
        case .dnsUpdateFailed:
            "The DNS validation record could not be created."
        case .dnsCleanupFailed:
            "The DNS validation record could not be removed."
        case .issuanceFailed:
            "Certificate issuance failed."
        case .secureStorageFailed:
            "Certificate credentials could not be stored securely."
        case .invalidCertificateMaterial:
            "The certificate service returned invalid certificate material."
        case .identityUnavailable:
            "The relay TLS identity is unavailable."
        }
    }
}

enum ACMEHostname {
    static func normalized(_ hostname: String) throws -> String {
        var value = hostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        if value.hasSuffix(".") { value.removeLast() }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !value.isEmpty,
              value.utf8.count <= 253,
              labels.count >= 2,
              labels.allSatisfy({ label in
                  guard !label.isEmpty,
                        label.utf8.count <= 63,
                        label.first != "-",
                        label.last != "-" else { return false }
                  return label.utf8.allSatisfy {
                      (48 ... 57).contains($0)
                          || (97 ... 122).contains($0)
                          || $0 == 45
                  }
              }) else {
            throw ACMECertificateError.invalidHostname
        }
        return value
    }
}
