import Foundation

enum CloudflareConfigurationError: Error, Equatable, LocalizedError {
    case invalidZoneDomain
    case invalidAccountID

    var errorDescription: String? {
        switch self {
        case .invalidZoneDomain:
            "Enter a valid ASCII DNS zone domain."
        case .invalidAccountID:
            "The Cloudflare account identifier is invalid."
        }
    }
}

struct CloudflareDNSConfiguration: Equatable, Sendable {
    let zoneDomain: String
    let accountID: String?
    let installationID: UUID
    let ownershipComment: String

    init(zoneDomain: String, accountID: String? = nil, installationID: UUID) throws {
        guard let normalizedDomain = Self.normalizedZoneDomain(zoneDomain) else {
            throw CloudflareConfigurationError.invalidZoneDomain
        }

        let normalizedAccountID: String?
        if let accountID {
            let trimmed = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.utf8.count == 32, Self.isValidIdentifier(trimmed) else {
                throw CloudflareConfigurationError.invalidAccountID
            }
            normalizedAccountID = trimmed
        } else {
            normalizedAccountID = nil
        }

        let installationValue = installationID.uuidString.lowercased()
        self.zoneDomain = normalizedDomain
        self.accountID = normalizedAccountID
        self.installationID = installationID
        self.ownershipComment = "Managed by ChannelDeck installation \(installationValue)"
    }

    fileprivate static func isValidIdentifier(_ value: String) -> Bool {
        guard (1 ... 128).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func normalizedZoneDomain(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard (1 ... 253).contains(normalized.utf8.count) else { return nil }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard (1 ... 63).contains(label.utf8.count) else { return nil }
            guard label.first != "-", label.last != "-" else { return nil }
            guard label.unicodeScalars.allSatisfy({ scalar in
                scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            }) else { return nil }
        }
        return normalized
    }
}

protocol CloudflareAPITokenProviding: Sendable {
    func apiToken() async throws -> String?
}

actor KeychainCloudflareTokenStore: CloudflareAPITokenProviding {
    private let keychain: any KeychainStoring
    private let installationID: UUID

    init(keychain: any KeychainStoring, installationID: UUID) {
        self.keychain = keychain
        self.installationID = installationID
    }

    func apiToken() async throws -> String? {
        try await keychain.cloudflareAPIToken(for: installationID)
    }

    func store(_ token: String) async throws {
        try await keychain.setCloudflareAPIToken(token, for: installationID)
    }

    func remove() async throws {
        try await keychain.setCloudflareAPIToken(nil, for: installationID)
    }
}

enum CloudflareTokenStatus: String, Equatable, Sendable, Decodable {
    case active
    case disabled
    case expired
}

enum CloudflareTokenVerification: Equatable, Sendable {
    case active(tokenID: String?)
    /// Some scoped tokens cannot call a token-introspection endpoint. Successful
    /// scoped zone discovery is the authoritative access check in that case.
    case zoneAccessConfirmed
}

struct CloudflareZone: Equatable, Sendable {
    let id: String
    let name: String
    let status: String
    let accountID: String?
}

enum CloudflareDNSRecordType: String, Codable, Sendable {
    case a = "A"
    case txt = "TXT"
}

struct CloudflareDNSRecord: Equatable, Sendable {
    let id: String
    let type: CloudflareDNSRecordType
    let name: String
    let content: String
    let proxied: Bool?
    let ttl: Int
    let tags: [String]
    let comment: String?
}

enum CloudflareDNSClientError: Error, Equatable, LocalizedError {
    case missingAPIToken
    case credentialUnavailable
    case invalidRecordName
    case invalidPrivateIPv4Address
    case invalidChallengeValue
    case authenticationFailed
    case insufficientPermissions
    case tokenNotActive(CloudflareTokenStatus)
    case zoneNotFound
    case ambiguousZone
    case recordConflict
    case recordNotFound
    case recordNotOwned
    case unexpectedHTTPStatus(Int)
    case apiFailure(codes: [Int])
    case responseTooLarge
    case invalidResponse
    case transportFailure(URLError.Code)
    case unexpectedTransportFailure

    var errorDescription: String? {
        switch self {
        case .missingAPIToken:
            "A Cloudflare API token is required."
        case .credentialUnavailable:
            "The Cloudflare credential could not be read securely."
        case .invalidRecordName:
            "The DNS record name is invalid or is outside the configured zone."
        case .invalidPrivateIPv4Address:
            "The relay address must be an RFC 1918 private IPv4 address."
        case .invalidChallengeValue:
            "The ACME DNS challenge value is invalid."
        case .authenticationFailed:
            "Cloudflare rejected the configured API token."
        case .insufficientPermissions:
            "The Cloudflare API token needs Zone DNS Edit and Zone Read access for this domain."
        case let .tokenNotActive(status):
            "The Cloudflare API token is \(status.rawValue)."
        case .zoneNotFound:
            "The configured Cloudflare zone was not found or is not active."
        case .ambiguousZone:
            "More than one Cloudflare zone matched the configuration."
        case .recordConflict:
            "A DNS record at this name is not owned by this ChannelDeck installation."
        case .recordNotFound:
            "The DNS record no longer exists."
        case .recordNotOwned:
            "ChannelDeck will not modify or delete a DNS record it does not own."
        case let .unexpectedHTTPStatus(status):
            "Cloudflare returned HTTP status \(status)."
        case let .apiFailure(codes):
            "Cloudflare rejected the request (codes: \(codes.map(String.init).joined(separator: ", ")))."
        case .responseTooLarge:
            "The Cloudflare response exceeded the allowed size."
        case .invalidResponse:
            "Cloudflare returned an invalid response."
        case let .transportFailure(code):
            "The Cloudflare request failed (network code \(code.rawValue))."
        case .unexpectedTransportFailure:
            "The Cloudflare request failed because of an unexpected network error."
        }
    }
}

/// A narrowly scoped Cloudflare v4 API client for ChannelDeck-owned DNS state.
/// It never stores its bearer token and never propagates server text, URLs, or
/// underlying errors that could contain request credentials.
actor CloudflareDNSClient {
    private let configuration: CloudflareDNSConfiguration
    private let tokenProvider: any CloudflareAPITokenProviding
    private let session: URLSession
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int
    private let apiBaseURL: URL
    private var cachedZone: CloudflareZone?

    init(
        configuration: CloudflareDNSConfiguration,
        tokenProvider: any CloudflareAPITokenProviding,
        session: URLSession? = nil,
        timeout: TimeInterval = 30,
        maximumResponseBytes: Int = 2 * 1_024 * 1_024,
        apiBaseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!
    ) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.httpCookieStorage = nil
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.urlCache = nil
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: sessionConfiguration,
                delegate: CloudflareNoRedirectDelegate.shared,
                delegateQueue: nil
            )
        }
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
        self.apiBaseURL = apiBaseURL
    }

    /// The zone lookup is the authoritative configuration check because it
    /// verifies that this exact token can read the configured zone scope.
    func verifyConfiguration() async throws -> CloudflareZone {
        try await discoverZone(forceRefresh: true)
    }

    /// Uses account-token introspection when an account ID is configured and
    /// user-token introspection otherwise. If a scoped token cannot introspect
    /// itself, an exact scoped zone lookup is accepted instead.
    func verifyToken() async throws -> CloudflareTokenVerification {
        let path: [String]
        if let accountID = configuration.accountID {
            path = ["accounts", accountID, "tokens", "verify"]
        } else {
            path = ["user", "tokens", "verify"]
        }

        do {
            let envelope: APIEnvelope<TokenVerificationDTO> = try await request(
                method: "GET",
                path: path
            )
            guard let verification = envelope.result else {
                throw CloudflareDNSClientError.invalidResponse
            }
            guard verification.status == .active else {
                throw CloudflareDNSClientError.tokenNotActive(verification.status)
            }
            return .active(tokenID: verification.id)
        } catch CloudflareDNSClientError.authenticationFailed {
            _ = try await discoverZone(forceRefresh: true)
            return .zoneAccessConfirmed
        } catch CloudflareDNSClientError.insufficientPermissions {
            _ = try await discoverZone(forceRefresh: true)
            return .zoneAccessConfirmed
        } catch CloudflareDNSClientError.apiFailure {
            _ = try await discoverZone(forceRefresh: true)
            return .zoneAccessConfirmed
        }
    }

    func discoverZone(forceRefresh: Bool = false) async throws -> CloudflareZone {
        if !forceRefresh, let cachedZone {
            return cachedZone
        }

        var queryItems = [
            URLQueryItem(name: "name", value: configuration.zoneDomain),
            URLQueryItem(name: "status", value: "active"),
            URLQueryItem(name: "match", value: "all"),
            URLQueryItem(name: "per_page", value: "50"),
        ]
        if let accountID = configuration.accountID {
            queryItems.append(URLQueryItem(name: "account.id", value: accountID))
        }

        let envelope: APIEnvelope<[ZoneDTO]> = try await request(
            method: "GET",
            path: ["zones"],
            queryItems: queryItems
        )
        guard let result = envelope.result else {
            throw CloudflareDNSClientError.invalidResponse
        }
        let exactMatches = result.filter { zone in
            zone.name.lowercased() == configuration.zoneDomain
                && zone.status.lowercased() == "active"
                && (configuration.accountID == nil || zone.account?.id == configuration.accountID)
        }
        guard !exactMatches.isEmpty else {
            throw CloudflareDNSClientError.zoneNotFound
        }
        guard exactMatches.count == 1, let dto = exactMatches.first else {
            throw CloudflareDNSClientError.ambiguousZone
        }
        guard CloudflareDNSConfiguration.isValidIdentifier(dto.id) else {
            throw CloudflareDNSClientError.invalidResponse
        }

        let zone = CloudflareZone(
            id: dto.id,
            name: dto.name,
            status: dto.status,
            accountID: dto.account?.id
        )
        cachedZone = zone
        return zone
    }

    @discardableResult
    func upsertPrivateARecord(name: String, ipv4Address: String) async throws -> CloudflareDNSRecord {
        guard Self.isRFC1918IPv4(ipv4Address) else {
            throw CloudflareDNSClientError.invalidPrivateIPv4Address
        }
        let recordName = try canonicalRecordName(name, allowsUnderscore: false)
        let zone = try await discoverZone()
        let matchingRecords = try await listRecords(zoneID: zone.id, type: .a, name: recordName)
        let owned = matchingRecords.filter(isOwned)
        let unowned = matchingRecords.filter { !isOwned($0) }

        guard unowned.isEmpty else {
            throw CloudflareDNSClientError.recordConflict
        }
        guard owned.count <= 1 else {
            throw CloudflareDNSClientError.recordConflict
        }

        let body = RecordMutationBody(
            type: .a,
            name: recordName,
            content: ipv4Address,
            ttl: 1,
            proxied: false,
            comment: configuration.ownershipComment
        )

        if let existing = owned.first {
            if existing.content == ipv4Address,
               existing.proxied == false,
               existing.ttl == 1,
               existing.comment == configuration.ownershipComment {
                return existing
            }
            return try await mutateRecord(
                method: "PUT",
                zoneID: zone.id,
                recordID: existing.id,
                body: body
            )
        }

        return try await mutateRecord(method: "POST", zoneID: zone.id, body: body)
    }

    @discardableResult
    func createACMETXTRecord(name: String, value: String) async throws -> CloudflareDNSRecord {
        let challengeName = try canonicalRecordName(name, allowsUnderscore: true)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedValue.isEmpty,
            trimmedValue.utf8.count <= 2_048,
            !trimmedValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw CloudflareDNSClientError.invalidChallengeValue
        }

        let zone = try await discoverZone()
        let matchingRecords = try await listRecords(zoneID: zone.id, type: .txt, name: challengeName)
        let exactMatches = matchingRecords.filter { $0.content == trimmedValue }
        guard !exactMatches.contains(where: { !isOwned($0) }) else {
            throw CloudflareDNSClientError.recordConflict
        }
        if let existing = exactMatches.first(where: isOwned) {
            return existing
        }

        let body = RecordMutationBody(
            type: .txt,
            name: challengeName,
            content: trimmedValue,
            ttl: 120,
            proxied: nil,
            comment: configuration.ownershipComment
        )
        return try await mutateRecord(method: "POST", zoneID: zone.id, body: body)
    }

    func deleteACMETXTRecord(recordID: String, expectedName: String? = nil) async throws {
        let zone = try await discoverZone()
        let record = try await getRecord(zoneID: zone.id, recordID: recordID)
        guard record.type == .txt else {
            throw CloudflareDNSClientError.recordNotOwned
        }
        if let expectedName {
            let canonicalExpectedName = try canonicalRecordName(expectedName, allowsUnderscore: true)
            guard record.name == canonicalExpectedName else {
                throw CloudflareDNSClientError.recordNotOwned
            }
        }
        try await delete(record: record, zoneID: zone.id)
    }

    func deleteOwnedRecord(recordID: String) async throws {
        let zone = try await discoverZone()
        let record = try await getRecord(zoneID: zone.id, recordID: recordID)
        try await delete(record: record, zoneID: zone.id)
    }

    private func delete(record: CloudflareDNSRecord, zoneID: String) async throws {
        guard isOwned(record) else {
            throw CloudflareDNSClientError.recordNotOwned
        }
        let _: APIEnvelope<DeletedRecordDTO> = try await request(
            method: "DELETE",
            path: ["zones", zoneID, "dns_records", record.id]
        )
    }

    private func mutateRecord(
        method: String,
        zoneID: String,
        recordID: String? = nil,
        body: RecordMutationBody
    ) async throws -> CloudflareDNSRecord {
        var path = ["zones", zoneID, "dns_records"]
        if let recordID {
            guard CloudflareDNSConfiguration.isValidIdentifier(recordID) else {
                throw CloudflareDNSClientError.invalidResponse
            }
            path.append(recordID)
        }
        let encodedBody: Data
        do {
            encodedBody = try JSONEncoder().encode(body)
        } catch {
            throw CloudflareDNSClientError.invalidResponse
        }

        let envelope: APIEnvelope<RecordDTO> = try await request(
            method: method,
            path: path,
            body: encodedBody
        )
        guard let dto = envelope.result else {
            throw CloudflareDNSClientError.invalidResponse
        }
        return try record(from: dto)
    }

    private func getRecord(zoneID: String, recordID: String) async throws -> CloudflareDNSRecord {
        guard CloudflareDNSConfiguration.isValidIdentifier(recordID) else {
            throw CloudflareDNSClientError.recordNotFound
        }
        do {
            let envelope: APIEnvelope<RecordDTO> = try await request(
                method: "GET",
                path: ["zones", zoneID, "dns_records", recordID]
            )
            guard let dto = envelope.result else {
                throw CloudflareDNSClientError.invalidResponse
            }
            return try record(from: dto)
        } catch CloudflareDNSClientError.unexpectedHTTPStatus(404) {
            throw CloudflareDNSClientError.recordNotFound
        }
    }

    private func listRecords(
        zoneID: String,
        type: CloudflareDNSRecordType,
        name: String
    ) async throws -> [CloudflareDNSRecord] {
        var page = 1
        var records: [CloudflareDNSRecord] = []
        while true {
            let envelope: APIEnvelope<[RecordDTO]> = try await request(
                method: "GET",
                path: ["zones", zoneID, "dns_records"],
                queryItems: [
                    URLQueryItem(name: "type", value: type.rawValue),
                    URLQueryItem(name: "name", value: name),
                    URLQueryItem(name: "match", value: "all"),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "per_page", value: "100"),
                ]
            )
            guard let pageResult = envelope.result else {
                throw CloudflareDNSClientError.invalidResponse
            }
            records.append(contentsOf: try pageResult.map(record(from:)))

            let totalPages = max(envelope.resultInfo?.totalPages ?? 1, 1)
            guard page < totalPages else { return records }
            guard page < 100 else {
                throw CloudflareDNSClientError.invalidResponse
            }
            page += 1
        }
    }

    private func record(from dto: RecordDTO) throws -> CloudflareDNSRecord {
        guard CloudflareDNSConfiguration.isValidIdentifier(dto.id) else {
            throw CloudflareDNSClientError.invalidResponse
        }
        return CloudflareDNSRecord(
            id: dto.id,
            type: dto.type,
            name: dto.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            content: dto.content,
            proxied: dto.proxied,
            ttl: dto.ttl,
            tags: dto.tags ?? [],
            comment: dto.comment
        )
    }

    private func isOwned(_ record: CloudflareDNSRecord) -> Bool {
        record.comment == configuration.ownershipComment
    }

    private func canonicalRecordName(_ value: String, allowsUnderscore: Bool) throws -> String {
        var normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if normalized == "@" {
            normalized = configuration.zoneDomain
        } else if !normalized.contains(".") {
            normalized += ".\(configuration.zoneDomain)"
        }
        guard
            normalized == configuration.zoneDomain
                || normalized.hasSuffix(".\(configuration.zoneDomain)"),
            normalized.utf8.count <= 253
        else {
            throw CloudflareDNSClientError.invalidRecordName
        }

        for label in normalized.split(separator: ".", omittingEmptySubsequences: false) {
            guard (1 ... 63).contains(label.utf8.count), label.first != "-", label.last != "-" else {
                throw CloudflareDNSClientError.invalidRecordName
            }
            let valid = label.unicodeScalars.allSatisfy { scalar in
                guard scalar.isASCII else { return false }
                if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" { return true }
                return allowsUnderscore && scalar == "_"
            }
            guard valid else {
                throw CloudflareDNSClientError.invalidRecordName
            }
        }
        return normalized
    }

    private static func isRFC1918IPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard
                !part.isEmpty,
                part.count <= 3,
                part.allSatisfy(\.isNumber),
                (part.count == 1 || part.first != "0"),
                let octet = Int(part),
                (0 ... 255).contains(octet)
            else { return false }
            octets.append(octet)
        }
        return octets[0] == 10
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    private func request<Result: Decodable>(
        method: String,
        path: [String],
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> APIEnvelope<Result> {
        let token: String
        do {
            guard let storedToken = try await tokenProvider.apiToken(), !storedToken.isEmpty else {
                throw CloudflareDNSClientError.missingAPIToken
            }
            token = storedToken
        } catch let error as CloudflareDNSClientError {
            throw error
        } catch {
            throw CloudflareDNSClientError.credentialUnavailable
        }

        guard let url = makeURL(path: path, queryItems: queryItems) else {
            throw CloudflareDNSClientError.invalidResponse
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudflareDNSClientError.invalidResponse
            }
            guard data.count <= maximumResponseBytes else {
                throw CloudflareDNSClientError.responseTooLarge
            }

            if httpResponse.statusCode == 401 {
                throw CloudflareDNSClientError.authenticationFailed
            }
            if httpResponse.statusCode == 403 {
                throw CloudflareDNSClientError.insufficientPermissions
            }
            if httpResponse.statusCode == 404 {
                throw CloudflareDNSClientError.unexpectedHTTPStatus(404)
            }
            let envelope: APIEnvelope<Result>
            do {
                envelope = try JSONDecoder().decode(APIEnvelope<Result>.self, from: data)
            } catch {
                throw CloudflareDNSClientError.invalidResponse
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let codes = envelope.errors.map(\.code)
                if !codes.isEmpty { throw CloudflareDNSClientError.apiFailure(codes: codes) }
                throw CloudflareDNSClientError.unexpectedHTTPStatus(httpResponse.statusCode)
            }
            guard envelope.success else {
                let codes = envelope.errors.map(\.code)
                throw codes.isEmpty
                    ? CloudflareDNSClientError.invalidResponse
                    : CloudflareDNSClientError.apiFailure(codes: codes)
            }
            return envelope
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CloudflareDNSClientError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw CloudflareDNSClientError.transportFailure(error.code)
        } catch {
            throw CloudflareDNSClientError.unexpectedTransportFailure
        }
    }

    private func makeURL(path: [String], queryItems: [URLQueryItem]) -> URL? {
        guard apiBaseURL.scheme?.lowercased() == "https",
              apiBaseURL.host?.isEmpty == false,
              apiBaseURL.user == nil,
              apiBaseURL.password == nil else { return nil }
        var url = apiBaseURL
        for component in path {
            guard CloudflareDNSConfiguration.isValidIdentifier(component) else { return nil }
            url.appendPathComponent(component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }
}

private final class CloudflareNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = CloudflareNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A bearer credential must never be replayed to a redirected origin.
        completionHandler(nil)
    }
}

extension CloudflareDNSClient: DNSChallengeProviding {
    func presentTXTRecord(name: String, value: String) async throws -> DNSChallengeRecord {
        let record = try await createACMETXTRecord(name: name, value: value)
        return DNSChallengeRecord(id: record.id, name: record.name)
    }

    func removeTXTRecord(_ record: DNSChallengeRecord) async throws {
        try await deleteACMETXTRecord(recordID: record.id, expectedName: record.name)
    }
}

private struct APIEnvelope<Result: Decodable>: Decodable {
    let success: Bool
    let result: Result?
    let errors: [APIErrorDTO]
    let resultInfo: ResultInfoDTO?

    private enum CodingKeys: String, CodingKey {
        case success
        case result
        case errors
        case resultInfo = "result_info"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        result = try container.decodeIfPresent(Result.self, forKey: .result)
        errors = try container.decodeIfPresent([APIErrorDTO].self, forKey: .errors) ?? []
        resultInfo = try container.decodeIfPresent(ResultInfoDTO.self, forKey: .resultInfo)
    }
}

private struct APIErrorDTO: Decodable {
    let code: Int
}

private struct ResultInfoDTO: Decodable {
    let totalPages: Int?

    private enum CodingKeys: String, CodingKey {
        case totalPages = "total_pages"
    }
}

private struct ZoneDTO: Decodable {
    let id: String
    let name: String
    let status: String
    let account: AccountDTO?
}

private struct AccountDTO: Decodable {
    let id: String
}

private struct TokenVerificationDTO: Decodable {
    let id: String?
    let status: CloudflareTokenStatus
}

private struct RecordDTO: Decodable {
    let id: String
    let type: CloudflareDNSRecordType
    let name: String
    let content: String
    let proxied: Bool?
    let ttl: Int
    let tags: [String]?
    let comment: String?
}

private struct DeletedRecordDTO: Decodable {
    let id: String
}

private struct RecordMutationBody: Encodable {
    let type: CloudflareDNSRecordType
    let name: String
    let content: String
    let ttl: Int
    let proxied: Bool?
    let comment: String
}
