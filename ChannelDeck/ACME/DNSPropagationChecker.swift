import Foundation

/// Checks the resolver-visible DNS view over encrypted HTTPS. The challenge
/// value is used only for an in-memory comparison and is never sent in the
/// request, retained by this actor, or included in an error or log message.
actor DoHTXTPropagationChecker: DNSPropagationChecking {
    private let session: URLSession
    private let resolverURL: URL
    private let requestTimeout: TimeInterval
    private let maximumResponseBytes: Int

    init(
        session: URLSession? = nil,
        resolverURL: URL = URL(string: "https://cloudflare-dns.com/dns-query")!,
        requestTimeout: TimeInterval = 10,
        maximumResponseBytes: Int = 64 * 1_024
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(
                configuration: configuration,
                delegate: DoHNoRedirectDelegate.shared,
                delegateQueue: nil
            )
        }
        self.resolverURL = resolverURL
        self.requestTimeout = requestTimeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    func checkTXTRecord(name: String, value: String) async throws -> DNSPropagationStatus {
        guard
            requestTimeout > 0,
            maximumResponseBytes > 0,
            Self.isValidDNSName(name),
            Self.isValidChallengeValue(value),
            let url = makeQueryURL(name: name)
        else {
            return .pending
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode),
                  httpResponse.expectedContentLength <= Int64(maximumResponseBytes)
                    || httpResponse.expectedContentLength < 0 else {
                return .pending
            }

            var data = Data()
            data.reserveCapacity(
                httpResponse.expectedContentLength > 0
                    ? min(Int(httpResponse.expectedContentLength), maximumResponseBytes)
                    : 0
            )
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumResponseBytes else {
                    return .pending
                }
                data.append(byte)
            }

            let answer = try JSONDecoder().decode(DoHResponse.self, from: data)
            // NOERROR with no matching answer, NXDOMAIN (3), and SERVFAIL (2)
            // are all inconclusive while propagation is still in progress.
            guard answer.status == 0 else { return .pending }
            let values = (answer.answers ?? [])
                .filter { $0.type == 16 }
                .compactMap { Self.decodeTXTPresentation($0.data) }
            return values.contains(value) ? .visible : .pending
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        } catch {
            // Resolver/network failures are transient observations. The manager
            // retries them under the overall ACME operation deadline.
            return .pending
        }
    }

    private func makeQueryURL(name: String) -> URL? {
        guard resolverURL.scheme?.lowercased() == "https",
              resolverURL.host?.isEmpty == false,
              resolverURL.user == nil,
              resolverURL.password == nil,
              var components = URLComponents(url: resolverURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.query = nil
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "type", value: "TXT"),
            // Keep DNSSEC validation enabled in the resolver-visible view.
            URLQueryItem(name: "cd", value: "false"),
        ]
        return components.url
    }

    private static func isValidDNSName(_ name: String) -> Bool {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix(".") { normalized.removeLast() }
        guard !normalized.isEmpty, normalized.utf8.count <= 253 else { return false }
        return normalized.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1 ... 63).contains(label.utf8.count),
                  label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "-"
                        || scalar == "_")
            }
        }
    }

    private static func isValidChallengeValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 2_048
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// Decodes the RFC 1035 presentation form used by the JSON DoH API,
    /// including TXT values split into multiple quoted character strings.
    private static func decodeTXTPresentation(_ presentation: String) -> String? {
        let scalars = Array(presentation.unicodeScalars)
        var index = 0
        var output = String.UnicodeScalarView()
        var foundQuotedString = false

        func skipWhitespace() {
            while index < scalars.count, CharacterSet.whitespaces.contains(scalars[index]) {
                index += 1
            }
        }

        skipWhitespace()
        while index < scalars.count {
            guard scalars[index] == "\"" else { return nil }
            foundQuotedString = true
            index += 1
            var closed = false
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" {
                    closed = true
                    break
                }
                if scalar == "\\" {
                    guard index < scalars.count else { return nil }
                    if index + 2 < scalars.count,
                       scalars[index].properties.numericType == .decimal,
                       scalars[index + 1].properties.numericType == .decimal,
                       scalars[index + 2].properties.numericType == .decimal {
                        let digits = String(String.UnicodeScalarView(scalars[index ... index + 2]))
                        guard let byte = UInt8(digits) else { return nil }
                        output.append(UnicodeScalar(byte))
                        index += 3
                    } else {
                        output.append(scalars[index])
                        index += 1
                    }
                } else {
                    output.append(scalar)
                }
            }
            guard closed else { return nil }
            skipWhitespace()
        }
        return foundQuotedString ? String(output) : nil
    }
}

private struct DoHResponse: Decodable {
    let status: Int
    let answers: [DoHAnswer]?

    private enum CodingKeys: String, CodingKey {
        case status = "Status"
        case answers = "Answer"
    }
}

private struct DoHAnswer: Decodable {
    let type: Int
    let data: String
}

private final class DoHNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = DoHNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
