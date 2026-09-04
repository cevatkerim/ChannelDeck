import Foundation
import Security

/// Secrets stored by ChannelDeck. A source or installation UUID is always part
/// of the Keychain account, so independently managed values cannot collide.
enum KeychainSecretKind: String, CaseIterable, Sendable {
    case playlistURL = "playlist-url"
    case epgURL = "epg-url"
    case playlistCacheKey = "playlist-cache-key"
    case cloudflareAPIToken = "cloudflare-api-token"
}

protocol KeychainStoring: Sendable {
    func data(for playlistID: UUID, kind: KeychainSecretKind) async throws -> Data?
    func setData(_ data: Data, for playlistID: UUID, kind: KeychainSecretKind) async throws
    func removeData(for playlistID: UUID, kind: KeychainSecretKind) async throws
    func removeAll(for playlistID: UUID) async throws
}

extension KeychainStoring {
    func cloudflareAPIToken(for installationID: UUID) async throws -> String? {
        guard let data = try await data(for: installationID, kind: .cloudflareAPIToken) else {
            return nil
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidStoredValue
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= 4_096,
            !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw KeychainStoreError.invalidStoredValue
        }
        return trimmed
    }

    func setCloudflareAPIToken(_ token: String?, for installationID: UUID) async throws {
        guard let token else {
            try await removeData(for: installationID, kind: .cloudflareAPIToken)
            return
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= 4_096,
            !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw KeychainStoreError.invalidStoredValue
        }
        try await setData(Data(trimmed.utf8), for: installationID, kind: .cloudflareAPIToken)
    }

    func playlistURL(for playlistID: UUID) async throws -> URL? {
        try await url(for: playlistID, kind: .playlistURL)
    }

    func setPlaylistURL(_ url: URL, for playlistID: UUID) async throws {
        try await setURL(url, for: playlistID, kind: .playlistURL)
    }

    func epgURL(for playlistID: UUID) async throws -> URL? {
        try await url(for: playlistID, kind: .epgURL)
    }

    func setEPGURL(_ url: URL?, for playlistID: UUID) async throws {
        if let url {
            try await setURL(url, for: playlistID, kind: .epgURL)
        } else {
            try await removeData(for: playlistID, kind: .epgURL)
        }
    }

    private func url(for playlistID: UUID, kind: KeychainSecretKind) async throws -> URL? {
        guard let data = try await data(for: playlistID, kind: kind) else {
            return nil
        }
        guard
            let value = String(data: data, encoding: .utf8),
            let url = URL(string: value),
            url.scheme != nil
        else {
            throw KeychainStoreError.invalidStoredValue
        }
        return url
    }

    private func setURL(_ url: URL, for playlistID: UUID, kind: KeychainSecretKind) async throws {
        guard let data = url.absoluteString.data(using: .utf8) else {
            throw KeychainStoreError.invalidStoredValue
        }
        try await setData(data, for: playlistID, kind: kind)
    }
}

enum KeychainStoreError: Error, Equatable, LocalizedError {
    case invalidStoredValue
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredValue:
            "A stored credential is invalid."
        case let .unexpectedStatus(status):
            "The secure credential store failed (status \(status))."
        }
    }
}

/// Production Security-framework implementation. All operations are serialized
/// by the actor, including the read/update/add sequence used for upserts.
actor KeychainStore: KeychainStoring {
    private let service: String

    init(service: String = "com.kerimincedayi.ChannelDeck.playlist-secrets") {
        self.service = service
    }

    func data(for playlistID: UUID, kind: KeychainSecretKind) throws -> Data? {
        var query = baseQuery(for: playlistID, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainStoreError.invalidStoredValue
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func setData(_ data: Data, for playlistID: UUID, kind: KeychainSecretKind) throws {
        let query = baseQuery(for: playlistID, kind: kind)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    func removeData(for playlistID: UUID, kind: KeychainSecretKind) throws {
        let status = SecItemDelete(baseQuery(for: playlistID, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    func removeAll(for playlistID: UUID) throws {
        for kind in KeychainSecretKind.allCases {
            try removeData(for: playlistID, kind: kind)
        }
    }

    private func baseQuery(for playlistID: UUID, kind: KeychainSecretKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(playlistID.uuidString.lowercased()).\(kind.rawValue)",
        ]
    }
}
