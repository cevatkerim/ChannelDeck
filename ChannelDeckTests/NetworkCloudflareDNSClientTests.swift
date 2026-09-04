import Foundation
import XCTest
@testable import ChannelDeck

final class NetworkCloudflareDNSClientTests: XCTestCase {
    private let zoneID = "0123456789abcdef0123456789abcdef"
    private let accountID = "abcdef0123456789abcdef0123456789"

    override func tearDown() {
        CloudflareURLProtocol.handler = nil
        super.tearDown()
    }

    func testConfigurationNormalizesZoneAndCreatesStableOwnershipMetadata() throws {
        let installationID = UUID(uuidString: "5F392E6E-4633-4C38-814B-D5E23B4CE361")!
        let configuration = try CloudflareDNSConfiguration(
            zoneDomain: " Example.COM. ",
            accountID: accountID,
            installationID: installationID
        )

        XCTAssertEqual(configuration.zoneDomain, "example.com")
        XCTAssertEqual(configuration.accountID, accountID)
        XCTAssertTrue(configuration.ownershipComment.contains("5f392e6e-4633-4c38-814b-d5e23b4ce361"))
        XCTAssertThrowsError(
            try CloudflareDNSConfiguration(zoneDomain: "not a domain", installationID: UUID())
        )
        XCTAssertThrowsError(
            try CloudflareDNSConfiguration(
                zoneDomain: "example.com",
                accountID: "too-short",
                installationID: UUID()
            )
        )
    }

    func testKeychainTokenStoreUsesInstallationScopedSecret() async throws {
        let keychain = CloudflareMemoryKeychain()
        let installationID = UUID()
        let store = KeychainCloudflareTokenStore(keychain: keychain, installationID: installationID)

        try await store.store("  test-token  ")
        let storedToken = try await store.apiToken()
        XCTAssertEqual(storedToken, "test-token")
        let storedKind = await keychain.lastWrittenKind
        let storedID = await keychain.lastWrittenID
        XCTAssertEqual(storedKind, .cloudflareAPIToken)
        XCTAssertEqual(storedID, installationID)

        try await store.remove()
        let removedToken = try await store.apiToken()
        XCTAssertNil(removedToken)
    }

    func testScopedZoneDiscoveryUsesDomainAccountAndBearerToken() async throws {
        let session = makeSession { [zoneID, accountID] request in
            XCTAssertEqual(request.url?.path, "/client/v4/zones")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-test-token")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "name" })?.value, "example.com")
            XCTAssertEqual(query?.first(where: { $0.name == "account.id" })?.value, accountID)
            return Self.jsonResponse(
                request,
                body: Self.zoneEnvelope(zoneID: zoneID, accountID: accountID)
            )
        }
        defer { session.invalidateAndCancel() }
        let client = try makeClient(session: session)

        let zone = try await client.verifyConfiguration()

        XCTAssertEqual(zone.id, zoneID)
        XCTAssertEqual(zone.name, "example.com")
        XCTAssertEqual(zone.accountID, accountID)
    }

    func testAccountTokenVerificationUsesAccountEndpoint() async throws {
        let session = makeSession { [accountID] request in
            XCTAssertEqual(request.url?.path, "/client/v4/accounts/\(accountID)/tokens/verify")
            return Self.jsonResponse(
                request,
                body: """
                {"success":true,"errors":[],"result":{"id":"token-id","status":"active"}}
                """
            )
        }
        defer { session.invalidateAndCancel() }

        let verification = try await makeClient(session: session).verifyToken()

        XCTAssertEqual(verification, .active(tokenID: "token-id"))
    }

    func testUserTokenIntrospectionFailureFallsBackToAuthoritativeZoneAccess() async throws {
        let configuration = try CloudflareDNSConfiguration(
            zoneDomain: "example.com",
            installationID: UUID()
        )
        let session = makeSession { [zoneID] request in
            if request.url?.path == "/client/v4/user/tokens/verify" {
                return Self.jsonResponse(request, status: 401, body: "{}")
            }
            return Self.jsonResponse(
                request,
                body: Self.zoneEnvelope(zoneID: zoneID, accountID: nil)
            )
        }
        defer { session.invalidateAndCancel() }
        let client = CloudflareDNSClient(
            configuration: configuration,
            tokenProvider: CloudflareStaticTokenProvider(token: "scoped-token"),
            session: session
        )

        let verification = try await client.verifyToken()
        XCTAssertEqual(verification, .zoneAccessConfirmed)
    }

    func testForbiddenDNSAccessReportsMissingPermissions() async throws {
        let session = makeSession { request in
            Self.jsonResponse(request, status: 403, body: "{}")
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await makeClient(session: session).verifyConfiguration()
            XCTFail("Expected a permission error")
        } catch {
            XCTAssertEqual(error as? CloudflareDNSClientError, .insufficientPermissions)
        }
    }

    func testCreatesDNSOnlyPrivateARecordWithOwnershipComment() async throws {
        let configuration = try configuration()
        let session = makeSession { [zoneID, accountID] request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/client/v4/zones"):
                return Self.jsonResponse(
                    request,
                    body: Self.zoneEnvelope(zoneID: zoneID, accountID: accountID)
                )
            case ("GET", "/client/v4/zones/\(zoneID)/dns_records"):
                return Self.jsonResponse(
                    request,
                    body: "{\"success\":true,\"errors\":[],\"result\":[],\"result_info\":{\"total_pages\":1}}"
                )
            case ("POST", "/client/v4/zones/\(zoneID)/dns_records"):
                let body = try Self.jsonBody(request)
                XCTAssertEqual(body["type"] as? String, "A")
                XCTAssertEqual(body["name"] as? String, "relay.example.com")
                XCTAssertEqual(body["content"] as? String, "192.168.50.12")
                XCTAssertEqual(body["proxied"] as? Bool, false)
                XCTAssertEqual(body["ttl"] as? Int, 1)
                XCTAssertNil(body["tags"])
                XCTAssertEqual(body["comment"] as? String, configuration.ownershipComment)
                return Self.jsonResponse(
                    request,
                    body: Self.recordEnvelope(
                        id: "record00000000000000000000000001",
                        type: "A",
                        name: "relay.example.com",
                        content: "192.168.50.12",
                        proxied: false,
                        ttl: 1,
                        tag: nil,
                        comment: configuration.ownershipComment
                    )
                )
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil")")
                return Self.jsonResponse(request, status: 500, body: "{}")
            }
        }
        defer { session.invalidateAndCancel() }
        let client = makeClient(configuration: configuration, session: session)

        let record = try await client.upsertPrivateARecord(
            name: "relay",
            ipv4Address: "192.168.50.12"
        )

        XCTAssertEqual(record.type, .a)
        XCTAssertEqual(record.proxied, false)
        XCTAssertEqual(record.comment, configuration.ownershipComment)
        XCTAssertTrue(record.tags.isEmpty)
    }

    func testUpdatesOwnedARecordAndRefusesUnownedRecord() async throws {
        let configuration = try configuration()
        let updateSession = makeSession { [zoneID, accountID] request in
            if request.url?.path == "/client/v4/zones" {
                return Self.jsonResponse(
                    request,
                    body: Self.zoneEnvelope(zoneID: zoneID, accountID: accountID)
                )
            }
            if request.httpMethod == "GET" {
                return Self.jsonResponse(
                    request,
                    body: Self.recordListEnvelope(
                        id: "record00000000000000000000000001",
                        type: "A",
                        name: "relay.example.com",
                        content: "192.168.1.2",
                        proxied: false,
                        ttl: 1,
                        tag: nil,
                        comment: configuration.ownershipComment
                    )
                )
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertTrue(request.url?.path.hasSuffix("/record00000000000000000000000001") == true)
            return Self.jsonResponse(
                request,
                body: Self.recordEnvelope(
                    id: "record00000000000000000000000001",
                    type: "A",
                    name: "relay.example.com",
                    content: "10.0.0.8",
                    proxied: false,
                    ttl: 1,
                    tag: nil,
                    comment: configuration.ownershipComment
                )
            )
        }
        defer { updateSession.invalidateAndCancel() }
        let updated = try await makeClient(
            configuration: configuration,
            session: updateSession
        ).upsertPrivateARecord(name: "relay.example.com", ipv4Address: "10.0.0.8")
        XCTAssertEqual(updated.content, "10.0.0.8")

        let conflictSession = makeSession { [zoneID, accountID] request in
            if request.url?.path == "/client/v4/zones" {
                return Self.jsonResponse(
                    request,
                    body: Self.zoneEnvelope(zoneID: zoneID, accountID: accountID)
                )
            }
            return Self.jsonResponse(
                request,
                body: Self.recordListEnvelope(
                    id: "record00000000000000000000000002",
                    type: "A",
                    name: "relay.example.com",
                    content: "192.168.1.10",
                    proxied: false,
                    ttl: 1,
                    tag: nil,
                    comment: nil
                )
            )
        }
        defer { conflictSession.invalidateAndCancel() }
        do {
            _ = try await makeClient(
                configuration: configuration,
                session: conflictSession
            ).upsertPrivateARecord(name: "relay", ipv4Address: "172.16.0.2")
            XCTFail("Expected ownership conflict")
        } catch {
            XCTAssertEqual(error as? CloudflareDNSClientError, .recordConflict)
        }
    }

    func testRejectsPublicIPv4AndOutOfZoneNamesBeforeMutation() async throws {
        let session = makeSession { request in
            XCTFail("No request expected")
            return Self.jsonResponse(request, status: 500, body: "{}")
        }
        defer { session.invalidateAndCancel() }
        let client = try makeClient(session: session)

        do {
            _ = try await client.upsertPrivateARecord(name: "relay", ipv4Address: "203.0.113.10")
            XCTFail("Expected public address rejection")
        } catch {
            XCTAssertEqual(error as? CloudflareDNSClientError, .invalidPrivateIPv4Address)
        }
        do {
            _ = try await client.createACMETXTRecord(
                name: "_acme-challenge.attacker.example",
                value: "challenge"
            )
            XCTFail("Expected out-of-zone name rejection")
        } catch {
            XCTAssertEqual(error as? CloudflareDNSClientError, .invalidRecordName)
        }
    }

    func testCreatesAndDeletesOnlyOwnedACMETXTRecord() async throws {
        let configuration = try configuration()
        let recordID = "record00000000000000000000000003"
        let session = makeSession { [zoneID, accountID] request in
            let path = request.url?.path
            if path == "/client/v4/zones" {
                return Self.jsonResponse(
                    request,
                    body: Self.zoneEnvelope(zoneID: zoneID, accountID: accountID)
                )
            }
            if request.httpMethod == "GET", path == "/client/v4/zones/\(zoneID)/dns_records" {
                return Self.jsonResponse(
                    request,
                    body: "{\"success\":true,\"errors\":[],\"result\":[],\"result_info\":{\"total_pages\":1}}"
                )
            }
            if request.httpMethod == "POST" {
                let body = try Self.jsonBody(request)
                XCTAssertEqual(body["type"] as? String, "TXT")
                XCTAssertNil(body["proxied"])
                return Self.jsonResponse(
                    request,
                    body: Self.recordEnvelope(
                        id: recordID,
                        type: "TXT",
                        name: "_acme-challenge.relay.example.com",
                        content: "dns-proof",
                        proxied: nil,
                        ttl: 120,
                        tag: nil,
                        comment: configuration.ownershipComment
                    )
                )
            }
            if request.httpMethod == "GET", path?.hasSuffix("/\(recordID)") == true {
                return Self.jsonResponse(
                    request,
                    body: Self.recordEnvelope(
                        id: recordID,
                        type: "TXT",
                        name: "_acme-challenge.relay.example.com",
                        content: "dns-proof",
                        proxied: nil,
                        ttl: 120,
                        tag: nil,
                        comment: configuration.ownershipComment
                    )
                )
            }
            XCTAssertEqual(request.httpMethod, "DELETE")
            return Self.jsonResponse(
                request,
                body: "{\"success\":true,\"errors\":[],\"result\":{\"id\":\"\(recordID)\"}}"
            )
        }
        defer { session.invalidateAndCancel() }
        let client = makeClient(configuration: configuration, session: session)

        let created = try await client.createACMETXTRecord(
            name: "_acme-challenge.relay.example.com",
            value: "dns-proof"
        )
        try await client.deleteACMETXTRecord(recordID: created.id)
    }

    func testRefusesToDeleteUnownedRecordAndRedactsServerText() async throws {
        let configuration = try configuration()
        let recordID = "record00000000000000000000000004"
        let session = makeSession { [zoneID, accountID] request in
            if request.url?.path == "/client/v4/zones" {
                return Self.jsonResponse(
                    request,
                    body: Self.zoneEnvelope(zoneID: zoneID, accountID: accountID)
                )
            }
            return Self.jsonResponse(
                request,
                body: Self.recordEnvelope(
                    id: recordID,
                    type: "TXT",
                    name: "_acme-challenge.example.com",
                    content: "secret-challenge",
                    proxied: nil,
                    ttl: 120,
                    tag: nil,
                    comment: "contains https://secret.invalid and unit-test-token"
                )
            )
        }
        defer { session.invalidateAndCancel() }

        do {
            try await makeClient(
                configuration: configuration,
                session: session
            ).deleteACMETXTRecord(recordID: recordID)
            XCTFail("Expected ownership protection")
        } catch {
            XCTAssertEqual(error as? CloudflareDNSClientError, .recordNotOwned)
            XCTAssertFalse(error.localizedDescription.contains("secret-challenge"))
            XCTAssertFalse(error.localizedDescription.contains("unit-test-token"))
            XCTAssertFalse(error.localizedDescription.contains("secret.invalid"))
        }
    }

    private func configuration() throws -> CloudflareDNSConfiguration {
        try CloudflareDNSConfiguration(
            zoneDomain: "example.com",
            accountID: accountID,
            installationID: UUID(uuidString: "5F392E6E-4633-4C38-814B-D5E23B4CE361")!
        )
    }

    private func makeClient(session: URLSession) throws -> CloudflareDNSClient {
        makeClient(configuration: try configuration(), session: session)
    }

    private func makeClient(
        configuration: CloudflareDNSConfiguration,
        session: URLSession
    ) -> CloudflareDNSClient {
        CloudflareDNSClient(
            configuration: configuration,
            tokenProvider: CloudflareStaticTokenProvider(token: "unit-test-token"),
            session: session
        )
    }

    private func makeSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        CloudflareURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudflareURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func zoneEnvelope(zoneID: String, accountID: String?) -> String {
        let account = accountID.map { "\"account\":{\"id\":\"\($0)\"}," } ?? ""
        return "{\"success\":true,\"errors\":[],\"result\":[{\"id\":\"\(zoneID)\",\(account)\"name\":\"example.com\",\"status\":\"active\"}]}"
    }

    private static func recordEnvelope(
        id: String,
        type: String,
        name: String,
        content: String,
        proxied: Bool?,
        ttl: Int,
        tag: String?,
        comment: String?
    ) -> String {
        let record = recordJSON(
            id: id,
            type: type,
            name: name,
            content: content,
            proxied: proxied,
            ttl: ttl,
            tag: tag,
            comment: comment
        )
        return "{\"success\":true,\"errors\":[],\"result\":\(record)}"
    }

    private static func recordListEnvelope(
        id: String,
        type: String,
        name: String,
        content: String,
        proxied: Bool?,
        ttl: Int,
        tag: String?,
        comment: String?
    ) -> String {
        let record = recordJSON(
            id: id,
            type: type,
            name: name,
            content: content,
            proxied: proxied,
            ttl: ttl,
            tag: tag,
            comment: comment
        )
        return "{\"success\":true,\"errors\":[],\"result\":[\(record)],\"result_info\":{\"total_pages\":1}}"
    }

    private static func recordJSON(
        id: String,
        type: String,
        name: String,
        content: String,
        proxied: Bool?,
        ttl: Int,
        tag: String?,
        comment: String?
    ) -> String {
        let proxiedJSON = proxied.map { ",\"proxied\":\($0)" } ?? ""
        let tagsJSON = tag.map { "[\"\($0)\"]" } ?? "[]"
        let commentJSON = comment.map { "\"\($0)\"" } ?? "null"
        return "{\"id\":\"\(id)\",\"type\":\"\(type)\",\"name\":\"\(name)\",\"content\":\"\(content)\",\"ttl\":\(ttl)\(proxiedJSON),\"tags\":\(tagsJSON),\"comment\":\(commentJSON)}"
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            // URLSession may convert an HTTP body to a stream before handing
            // the request to URLProtocol on newer macOS SDKs.
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var streamedBody = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count == 0 { break }
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                streamedBody.append(buffer, count: count)
            }
            data = streamedBody
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func jsonResponse(
        _ request: URLRequest,
        status: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

private struct CloudflareStaticTokenProvider: CloudflareAPITokenProviding {
    let token: String?

    func apiToken() async throws -> String? { token }
}

private actor CloudflareMemoryKeychain: KeychainStoring {
    private var values: [String: Data] = [:]
    private(set) var lastWrittenKind: KeychainSecretKind?
    private(set) var lastWrittenID: UUID?

    func data(for playlistID: UUID, kind: KeychainSecretKind) -> Data? {
        values[key(playlistID, kind)]
    }

    func setData(_ data: Data, for playlistID: UUID, kind: KeychainSecretKind) {
        values[key(playlistID, kind)] = data
        lastWrittenKind = kind
        lastWrittenID = playlistID
    }

    func removeData(for playlistID: UUID, kind: KeychainSecretKind) {
        values.removeValue(forKey: key(playlistID, kind))
    }

    func removeAll(for playlistID: UUID) {
        for kind in KeychainSecretKind.allCases {
            values.removeValue(forKey: key(playlistID, kind))
        }
    }

    private func key(_ id: UUID, _ kind: KeychainSecretKind) -> String {
        "\(id.uuidString).\(kind.rawValue)"
    }
}

private final class CloudflareURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
