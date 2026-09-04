import CryptoKit
import Foundation
import Security

final class RelayTLSIdentity: @unchecked Sendable {
    let secIdentity: SecIdentity
    let certificateChain: [SecCertificate]
    let protocolIdentity: sec_identity_t

    init(
        secIdentity: SecIdentity,
        certificateChain: [SecCertificate],
        protocolIdentity: sec_identity_t
    ) {
        self.secIdentity = secIdentity
        self.certificateChain = certificateChain
        self.protocolIdentity = protocolIdentity
    }
}

actor ACMEKeychainMaterialStore: ACMEAccountCredentialStoring, RelayCertificateStoring {
    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String = "com.kerimincedayi.ChannelDeck.acme-material") {
        self.service = service
    }

    func accountCredentials(for directoryIdentifier: String) throws -> Data? {
        try data(account: "account.\(safeIdentifier(directoryIdentifier))")
    }

    func saveAccountCredentials(_ data: Data, for directoryIdentifier: String) throws {
        try setData(data, account: "account.\(safeIdentifier(directoryIdentifier))")
    }

    func loadCertificate() throws -> IssuedCertificateMaterial? {
        guard let stored = try data(account: "relay.identity") else { return nil }
        do {
            return try decoder.decode(IssuedCertificateMaterial.self, from: stored)
        } catch {
            throw ACMECertificateError.invalidCertificateMaterial
        }
    }

    func saveCertificate(_ certificate: IssuedCertificateMaterial) throws {
        do {
            encoder.outputFormatting = [.sortedKeys]
            try setData(encoder.encode(certificate), account: "relay.identity")
        } catch let error as ACMECertificateError {
            throw error
        } catch {
            throw ACMECertificateError.secureStorageFailed
        }
    }

    func removeCertificate() throws {
        try removeData(account: "relay.identity")
    }

    func loadIdentity() throws -> RelayTLSIdentity? {
        guard let certificate = try loadCertificate() else { return nil }
        return try RelayTLSIdentityFactory.makeIdentity(from: certificate)
    }

    private func data(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let value = result as? Data else {
                throw ACMECertificateError.secureStorageFailed
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw ACMECertificateError.secureStorageFailed
        }
    }

    private func setData(_ value: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ACMECertificateError.secureStorageFailed
            }
        default:
            throw ACMECertificateError.secureStorageFailed
        }
    }

    private func removeData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ACMECertificateError.secureStorageFailed
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func safeIdentifier(_ value: String) -> String {
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(value.unicodeScalars.filter { permitted.contains($0) }.prefix(96))
    }
}

enum RelayTLSIdentityFactory {
    static func makeIdentity(from material: IssuedCertificateMaterial) throws -> RelayTLSIdentity {
        guard !material.certificateChainPEM.isEmpty else {
            throw ACMECertificateError.invalidCertificateMaterial
        }
        let certificates = try material.certificateChainPEM.map(makeCertificate(from:))
        let privateKey = try makePrivateKey(from: material.privateKeyPEM)
        guard let identity = SecIdentityCreate(kCFAllocatorDefault, certificates[0], privateKey),
              let protocolIdentity = sec_identity_create_with_certificates(
                  identity,
                  certificates as CFArray
              ) else {
            throw ACMECertificateError.identityUnavailable
        }
        return RelayTLSIdentity(
            secIdentity: identity,
            certificateChain: certificates,
            protocolIdentity: protocolIdentity
        )
    }

    static func certificateExpiration(fromPEM pem: String) throws -> Date {
        let certificate = try makeCertificate(from: pem)
        guard let expiration = SecCertificateCopyNotValidAfterDate(certificate) else {
            throw ACMECertificateError.invalidCertificateMaterial
        }
        return expiration as Date
    }

    private static func makeCertificate(from pem: String) throws -> SecCertificate {
        guard let data = decodePEM(pem, type: "CERTIFICATE"),
              let certificate = SecCertificateCreateWithData(kCFAllocatorDefault, data as CFData) else {
            throw ACMECertificateError.invalidCertificateMaterial
        }
        return certificate
    }

    private static func makePrivateKey(from pem: String) throws -> SecKey {
        // AcmeSwift's P-256 finalization key is emitted as SEC1 PEM. Importing
        // that PEM through SecItemImport is unreliable on recent macOS
        // releases, while SecKeyCreateWithData accepts the key's ANSI X9.63
        // representation directly.
        if let p256Key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: 256,
            ]
            var importError: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(
                p256Key.x963Representation as CFData,
                attributes as CFDictionary,
                &importError
            ) {
                return key
            }
        }

        // Retain the generic importer as a compatibility fallback for any
        // future non-P256 ACME key material.
        guard let pemData = pem.data(using: .utf8) else {
            throw ACMECertificateError.invalidCertificateMaterial
        }
        var format = SecExternalFormat.formatPEMSequence
        var itemType = SecExternalItemType.itemTypePrivateKey
        var importedItems: CFArray?
        let status = SecItemImport(
            pemData as CFData,
            "key.pem" as CFString,
            &format,
            &itemType,
            [],
            nil,
            nil,
            &importedItems
        )
        guard status == errSecSuccess,
              let items = importedItems as? [Any] else {
            throw ACMECertificateError.invalidCertificateMaterial
        }
        for item in items {
            let value = item as CFTypeRef
            if CFGetTypeID(value) == SecKeyGetTypeID() {
                return unsafeDowncast(item as AnyObject, to: SecKey.self)
            }
        }
        throw ACMECertificateError.invalidCertificateMaterial
    }

    private static func decodePEM(_ pem: String, type: String) -> Data? {
        let header = "-----BEGIN \(type)-----"
        let footer = "-----END \(type)-----"
        guard let headerRange = pem.range(of: header),
              let footerRange = pem.range(of: footer),
              headerRange.upperBound <= footerRange.lowerBound else {
            return nil
        }
        let body = pem[headerRange.upperBound..<footerRange.lowerBound]
            .filter { !$0.isWhitespace }
        return Data(base64Encoded: String(body))
    }
}
