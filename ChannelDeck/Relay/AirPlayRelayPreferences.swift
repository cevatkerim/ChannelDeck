import Foundation
import Security

enum AirPlayRelayCertificateEnvironment: String, Codable, CaseIterable, Sendable {
    case production
    case staging

    var displayName: String {
        switch self {
        case .production: "Production (trusted)"
        case .staging: "Staging (testing only)"
        }
    }
}

/// Non-secret, installation-scoped relay preferences. Cloudflare tokens and
/// certificate key material deliberately live in Keychain instead.
struct AirPlayRelayPreferences: Codable, Equatable, Sendable {
    let installationID: UUID
    let hostLabel: String
    var zoneDomain: String
    var accountID: String
    var certificateEnvironment: AirPlayRelayCertificateEnvironment
    var dnsARecordID: String?

    var hostname: String? {
        let zone = zoneDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !zone.isEmpty else { return nil }
        return "\(hostLabel).\(zone)"
    }

    static func fresh(
        installationID: UUID = UUID(),
        randomBytes: () throws -> [UInt8] = AirPlayRelayRandom.bytes
    ) -> AirPlayRelayPreferences {
        let fallback = installationID.uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
        let suffix = (try? randomBytes())
            .map { $0.map { String(format: "%02x", $0) }.joined() }
            .flatMap { $0.count == 8 ? $0 : nil }
            ?? String(fallback)
        return AirPlayRelayPreferences(
            installationID: installationID,
            hostLabel: "iptv-\(suffix)",
            zoneDomain: "",
            accountID: "",
            certificateEnvironment: .production,
            dnsARecordID: nil
        )
    }
}

enum AirPlayRelayRandom {
    static func bytes() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AirPlayRelayPreferencesError.randomGenerationFailed
        }
        return bytes
    }
}

enum AirPlayRelayPreferencesError: LocalizedError {
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            "A unique relay hostname could not be generated."
        }
    }
}

@MainActor
final class AirPlayRelayPreferencesStore {
    private static let storageKey = "airPlayRelay.preferences.v1"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadOrCreate() -> AirPlayRelayPreferences {
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? decoder.decode(AirPlayRelayPreferences.self, from: data),
           Self.isValidInstallation(stored) {
            return stored
        }

        let fresh = AirPlayRelayPreferences.fresh()
        save(fresh)
        return fresh
    }

    func save(_ preferences: AirPlayRelayPreferences) {
        guard Self.isValidInstallation(preferences),
              let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Clears user configuration while preserving the per-installation
    /// identity and hostname label used to prove DNS record ownership.
    func clearConfiguration() -> AirPlayRelayPreferences {
        let current = loadOrCreate()
        let cleared = AirPlayRelayPreferences(
            installationID: current.installationID,
            hostLabel: current.hostLabel,
            zoneDomain: "",
            accountID: "",
            certificateEnvironment: .production,
            dnsARecordID: nil
        )
        save(cleared)
        return cleared
    }

    private static func isValidInstallation(_ preferences: AirPlayRelayPreferences) -> Bool {
        let suffix = preferences.hostLabel.dropFirst("iptv-".count)
        return preferences.hostLabel.hasPrefix("iptv-")
            && suffix.count == 8
            && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
