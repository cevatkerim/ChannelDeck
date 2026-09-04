import CryptoKit
import Foundation

enum EncryptedPlaylistCacheError: Error, Equatable, LocalizedError {
    case invalidEncryptionKey
    case snapshotTooLarge
    case authenticationFailed
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .invalidEncryptionKey:
            "The playlist cache encryption key is invalid."
        case .snapshotTooLarge:
            "The playlist snapshot exceeds the cache size limit."
        case .authenticationFailed:
            "The encrypted playlist snapshot could not be authenticated."
        case .storageFailure:
            "The encrypted playlist snapshot could not be accessed."
        }
    }
}

/// Encrypts last-known-good M3U bytes before they reach the filesystem.
actor EncryptedPlaylistCache {
    private static let encryptionOverhead = 64

    private let keyStore: any KeychainStoring
    private let directoryURL: URL
    private let maximumPlaintextBytes: Int
    private let fileManager: FileManager

    init(
        keyStore: any KeychainStoring,
        directoryURL: URL? = nil,
        maximumPlaintextBytes: Int = 50 * 1_024 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.keyStore = keyStore
        self.fileManager = fileManager
        self.maximumPlaintextBytes = maximumPlaintextBytes
        self.directoryURL = directoryURL ?? Self.defaultDirectory(fileManager: fileManager)
    }

    func store(_ plaintext: Data, for playlistID: UUID) async throws {
        guard plaintext.count <= maximumPlaintextBytes else {
            throw EncryptedPlaylistCacheError.snapshotTooLarge
        }

        let key = try await encryptionKey(for: playlistID)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw EncryptedPlaylistCacheError.storageFailure
        }
        guard let combined = sealedBox.combined else {
            throw EncryptedPlaylistCacheError.storageFailure
        }

        do {
            try prepareDirectory()
            let destination = snapshotURL(for: playlistID)
            try combined.write(to: destination, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: destination.path
            )
        } catch {
            throw EncryptedPlaylistCacheError.storageFailure
        }
    }

    func load(for playlistID: UUID) async throws -> Data? {
        let source = snapshotURL(for: playlistID)
        guard fileManager.fileExists(atPath: source.path) else {
            return nil
        }

        let encrypted: Data
        do {
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            if let byteCount = attributes[.size] as? NSNumber,
               byteCount.intValue > maximumPlaintextBytes + Self.encryptionOverhead {
                throw EncryptedPlaylistCacheError.snapshotTooLarge
            }
            encrypted = try Data(contentsOf: source, options: .mappedIfSafe)
        } catch let error as EncryptedPlaylistCacheError {
            throw error
        } catch {
            throw EncryptedPlaylistCacheError.storageFailure
        }

        guard let keyData = try await keyStore.data(for: playlistID, kind: .playlistCacheKey) else {
            throw EncryptedPlaylistCacheError.invalidEncryptionKey
        }
        let key = try key(from: keyData)

        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: key)
            guard plaintext.count <= maximumPlaintextBytes else {
                throw EncryptedPlaylistCacheError.snapshotTooLarge
            }
            return plaintext
        } catch let error as EncryptedPlaylistCacheError {
            throw error
        } catch {
            throw EncryptedPlaylistCacheError.authenticationFailed
        }
    }

    /// Removes the encrypted file and only its encryption key. The caller may
    /// remove the remaining source secrets with `KeychainStoring.removeAll`.
    func remove(for playlistID: UUID) async throws {
        let source = snapshotURL(for: playlistID)
        if fileManager.fileExists(atPath: source.path) {
            do {
                try fileManager.removeItem(at: source)
            } catch {
                throw EncryptedPlaylistCacheError.storageFailure
            }
        }
        try await keyStore.removeData(for: playlistID, kind: .playlistCacheKey)
    }

    private func encryptionKey(for playlistID: UUID) async throws -> SymmetricKey {
        if let existing = try await keyStore.data(for: playlistID, kind: .playlistCacheKey) {
            return try key(from: existing)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try await keyStore.setData(keyData, for: playlistID, kind: .playlistCacheKey)
        return newKey
    }

    private func key(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else {
            throw EncryptedPlaylistCacheError.invalidEncryptionKey
        }
        return SymmetricKey(data: data)
    }

    private func prepareDirectory() throws {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directoryURL.path
        )
    }

    private func snapshotURL(for playlistID: UUID) -> URL {
        directoryURL
            .appendingPathComponent(playlistID.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("playlist.aesgcm")
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("com.kerimincedayi.ChannelDeck", isDirectory: true)
            .appendingPathComponent("EncryptedPlaylists", isDirectory: true)
    }
}
