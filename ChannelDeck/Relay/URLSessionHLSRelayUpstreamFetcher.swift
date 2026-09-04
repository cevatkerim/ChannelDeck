import Foundation

/// URLSession-backed upstream transport for the local HLS relay. Production
/// defaults use an ephemeral session with no cookies or URL cache. URLSession
/// follows provider redirects and the final response URL is retained so nested
/// HLS references resolve against the actual origin.
actor URLSessionHLSRelayUpstreamFetcher: HLSRelayUpstreamFetching {
    private let session: URLSession
    private let timeout: TimeInterval
    private let maximumBodyBytes: Int

    init(
        session: URLSession? = nil,
        timeout: TimeInterval = 30,
        maximumBodyBytes: Int = 128 * 1_024 * 1_024
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        self.timeout = timeout
        self.maximumBodyBytes = maximumBodyBytes
    }

    func fetch(_ upstreamRequest: HLSRelayUpstreamRequest) async throws -> HLSRelayUpstreamResponse {
        guard
            let scheme = upstreamRequest.url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            upstreamRequest.url.host?.isEmpty == false
        else {
            throw HLSRelayError.upstreamFailure
        }

        var request = URLRequest(
            url: upstreamRequest.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = upstreamRequest.method.rawValue
        if let range = sanitizedHeader(upstreamRequest.range), range.lowercased().hasPrefix("bytes=") {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        if let etag = sanitizedHeader(upstreamRequest.ifNoneMatch) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let modified = sanitizedHeader(upstreamRequest.ifModifiedSince) {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            try Task.checkCancellation()
            let (receivedBody, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse,
                  let finalURL = httpResponse.url,
                  let finalScheme = finalURL.scheme?.lowercased(),
                  finalScheme == "http" || finalScheme == "https",
                  finalURL.host?.isEmpty == false,
                  (100 ... 599).contains(httpResponse.statusCode) else {
                throw HLSRelayError.upstreamFailure
            }

            let contentLength = parsedContentLength(from: httpResponse)
            if upstreamRequest.method == .get {
                guard receivedBody.count <= maximumBodyBytes else {
                    throw HLSRelayError.responseTooLarge
                }
                if let contentLength, contentLength > Int64(maximumBodyBytes) {
                    throw HLSRelayError.responseTooLarge
                }
            }

            return HLSRelayUpstreamResponse(
                statusCode: httpResponse.statusCode,
                body: upstreamRequest.method == .head ? Data() : receivedBody,
                finalURL: finalURL,
                contentType: safeResponseHeader(httpResponse.value(forHTTPHeaderField: "Content-Type")),
                contentLength: contentLength,
                contentRange: safeResponseHeader(httpResponse.value(forHTTPHeaderField: "Content-Range")),
                acceptRanges: safeResponseHeader(httpResponse.value(forHTTPHeaderField: "Accept-Ranges")),
                etag: safeResponseHeader(httpResponse.value(forHTTPHeaderField: "ETag")),
                lastModified: safeResponseHeader(httpResponse.value(forHTTPHeaderField: "Last-Modified")),
                cacheControl: safeResponseHeader(httpResponse.value(forHTTPHeaderField: "Cache-Control"))
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HLSRelayError {
            throw error
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        } catch {
            throw HLSRelayError.upstreamFailure
        }
    }

    private func parsedContentLength(from response: HTTPURLResponse) -> Int64? {
        if let rawValue = response.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(rawValue.trimmingCharacters(in: .whitespaces)),
           length >= 0 {
            return length
        }
        return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
    }

    private func sanitizedHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= 1_024,
            !trimmed.contains("\r"),
            !trimmed.contains("\n")
        else { return nil }
        return trimmed
    }

    private func safeResponseHeader(_ value: String?) -> String? {
        sanitizedHeader(value)
    }
}
