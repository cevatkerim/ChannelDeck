import CryptoKit
import Foundation

enum DNS01 {
    static func txtValue(forKeyAuthorization keyAuthorization: String) -> String {
        Data(SHA256.hash(data: Data(keyAuthorization.utf8))).base64URLEncodedString()
    }

    static func recordName(for hostname: String) throws -> String {
        var normalized = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("*.") {
            normalized.removeFirst(2)
        }
        return "_acme-challenge.\(try ACMEHostname.normalized(normalized))"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
