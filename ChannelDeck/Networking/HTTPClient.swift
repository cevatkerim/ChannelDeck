import Foundation

struct HTTPValidators: Equatable, Sendable {
    var etag: String?
    var lastModified: String?

    init(etag: String? = nil, lastModified: String? = nil) {
        self.etag = etag
        self.lastModified = lastModified
    }
}

struct HTTPResourcePolicy: Equatable, Sendable {
    let maximumResponseBytes: Int

    static let playlist = HTTPResourcePolicy(maximumResponseBytes: 50 * 1_024 * 1_024)
    static let epg = HTTPResourcePolicy(maximumResponseBytes: 200 * 1_024 * 1_024)
}

struct HTTPPayload: Equatable, Sendable {
    let data: Data
    let validators: HTTPValidators
    let contentType: String?
}

enum HTTPFetchResult: Equatable, Sendable {
    case modified(HTTPPayload)
    case notModified(HTTPValidators)
}

enum HTTPClientError: Error, Equatable, LocalizedError {
    case invalidURL
    case insecureTransport
    case invalidResponse
    case unacceptableStatus(Int)
    case responseTooLarge
    case transportFailure(URLError.Code)
    case unexpectedTransportFailure

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The source address is invalid."
        case .insecureTransport:
            "Playlist and programme-guide sources must use HTTPS."
        case .invalidResponse:
            "The server returned an invalid response."
        case let .unacceptableStatus(status):
            "The server returned HTTP status \(status)."
        case .responseTooLarge:
            "The server response exceeds the allowed size."
        case let .transportFailure(code):
            "The request failed (network code \(code.rawValue))."
        case .unexpectedTransportFailure:
            "The request failed because of an unexpected network error."
        }
    }
}

/// Fetches sensitive source documents without ever including their URLs in an
/// exposed error. `URLSession.data(for:)` participates in structured task
/// cancellation; a superseded repository refresh can simply cancel its task.
actor HTTPClient {
    private let session: URLSession
    private let timeout: TimeInterval

    init(session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.session = session
        self.timeout = timeout
    }

    func fetch(
        _ url: URL,
        validators: HTTPValidators? = nil,
        policy: HTTPResourcePolicy
    ) async throws -> HTTPFetchResult {
        guard
            url.scheme?.lowercased() == "https",
            let host = url.host,
            !host.isEmpty
        else {
            if url.scheme?.lowercased() == "http" {
                throw HTTPClientError.insecureTransport
            }
            throw HTTPClientError.invalidURL
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        request.setValue("application/x-mpegURL, application/xml, application/gzip, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let etag = safeHeaderValue(validators?.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = safeHeaderValue(validators?.lastModified) {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPClientError.invalidResponse
            }
            let responseValidators = mergedValidators(from: httpResponse, fallback: validators)

            if httpResponse.statusCode == 304 {
                return .notModified(responseValidators)
            }
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw HTTPClientError.unacceptableStatus(httpResponse.statusCode)
            }
            if httpResponse.expectedContentLength > Int64(policy.maximumResponseBytes) {
                throw HTTPClientError.responseTooLarge
            }
            guard data.count <= policy.maximumResponseBytes else {
                throw HTTPClientError.responseTooLarge
            }

            return .modified(
                HTTPPayload(
                    data: data,
                    validators: responseValidators,
                    contentType: safeHeaderValue(httpResponse.value(forHTTPHeaderField: "Content-Type"))
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw HTTPClientError.transportFailure(error.code)
        } catch {
            throw HTTPClientError.unexpectedTransportFailure
        }
    }

    private func mergedValidators(
        from response: HTTPURLResponse,
        fallback: HTTPValidators?
    ) -> HTTPValidators {
        HTTPValidators(
            etag: safeHeaderValue(response.value(forHTTPHeaderField: "ETag")) ?? fallback?.etag,
            lastModified: safeHeaderValue(response.value(forHTTPHeaderField: "Last-Modified")) ?? fallback?.lastModified
        )
    }

    /// Reject newlines to prevent a persisted response validator from becoming
    /// an injected request header. A small limit also bounds stored metadata.
    private func safeHeaderValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= 1_024,
            !trimmed.contains("\r"),
            !trimmed.contains("\n")
        else {
            return nil
        }
        return trimmed
    }
}
