import Foundation
import OSLog

/// A deliberately closed classification for relay responses. It carries no
/// request target, host, session token, upstream URL, headers, or media bytes.
enum HLSRelayDiagnosticRouteKind: String, Equatable, Sendable {
    case master
    case media
    case segment
    case upstream
}

/// Privacy-safe metadata for diagnosing receiver request progression without
/// retaining or logging any credential-bearing request data.
struct HLSRelayResponseDiagnostic: Equatable, Sendable {
    let routeKind: HLSRelayDiagnosticRouteKind
    let method: HLSRelayUpstreamMethod
    let statusCode: Int
    let responseBodyBytes: Int

    static func make(
        request: HLSRelayRequest,
        statusCode: Int,
        responseBodyBytes: Int
    ) -> HLSRelayResponseDiagnostic? {
        guard let routeKind = HLSRelayDiagnosticRouteKind(requestTarget: request.path) else {
            return nil
        }
        return HLSRelayResponseDiagnostic(
            routeKind: routeKind,
            method: request.method,
            statusCode: statusCode,
            responseBodyBytes: max(0, responseBodyBytes)
        )
    }
}

protocol HLSRelayResponseDiagnosticRecording: Sendable {
    func record(_ diagnostic: HLSRelayResponseDiagnostic)
}

/// Production diagnostics use only public, pre-sanitized scalar metadata.
/// OSLog never receives the original request or any value derived from its
/// hostname, token, resource identifier, query, or headers.
struct OSLogHLSRelayResponseDiagnosticRecorder: HLSRelayResponseDiagnosticRecording {
    private static let logger = Logger(
        subsystem: "com.kerimincedayi.ChannelDeck",
        category: "relay-response"
    )

    func record(_ diagnostic: HLSRelayResponseDiagnostic) {
        Self.logger.info(
            "route=\(diagnostic.routeKind.rawValue, privacy: .public) method=\(diagnostic.method.rawValue, privacy: .public) status=\(diagnostic.statusCode, privacy: .public) body_bytes=\(diagnostic.responseBodyBytes, privacy: .public)"
        )
    }
}

private extension HLSRelayDiagnosticRouteKind {
    init?(requestTarget: String) {
        guard let components = URLComponents(string: requestTarget),
              components.scheme == nil,
              components.host == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == components.path else {
            return nil
        }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3,
              parts[0] == "s",
              Self.isOpaqueToken(parts[1]) else {
            return nil
        }

        if parts.count == 3, parts[2] == "index.m3u8" {
            self = .upstream
            return
        }
        if parts.count == 4, parts[2] == "r", !parts[3].isEmpty {
            self = .upstream
            return
        }
        guard parts.count == 4, parts[2] == "transcoded" else {
            return nil
        }

        switch parts[3] {
        case "index.m3u8":
            self = .master
        case "media-0.m3u8":
            self = .media
        default:
            guard parts[3].range(
                of: #"^segment-0-[0-9]{9}\.ts$"#,
                options: .regularExpression
            ) != nil else {
                return nil
            }
            self = .segment
        }
    }

    static func isOpaqueToken(_ token: Substring) -> Bool {
        token.count >= 32
            && token.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber)
            }
    }
}
