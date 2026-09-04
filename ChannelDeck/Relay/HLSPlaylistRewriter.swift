import Foundation

enum HLSRelayResourceKind: Equatable, Sendable {
    case playlist
    case media
}

struct HLSPlaylistRewriter {
    typealias RelayURLProvider = (_ upstreamURL: URL, _ kind: HLSRelayResourceKind) throws -> URL

    func isHLSPlaylist(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let normalized = text.drop(while: { $0 == "\u{feff}" || $0.isWhitespace })
        return normalized.hasPrefix("#EXTM3U") && normalized.contains("#EXT-X-")
    }

    func rewrite(
        _ data: Data,
        relativeTo baseURL: URL,
        relayURL: RelayURLProvider
    ) throws -> Data {
        guard var text = String(data: data, encoding: .utf8) else {
            throw HLSRelayError.invalidPlaylistEncoding
        }
        if text.first == "\u{feff}" {
            text.removeFirst()
        }
        guard isHLSPlaylist(Data(text.utf8)) else {
            throw HLSRelayError.sourceIsNotHLS
        }

        let endsWithNewline = text.hasSuffix("\n")
        var previousTag = ""
        var rewrittenLines: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#") {
                let rewritten = try rewriteAttributeURIs(
                    in: line,
                    relativeTo: baseURL,
                    relayURL: relayURL
                )
                rewrittenLines.append(rewritten)
                previousTag = tagName(in: trimmed)
                continue
            }

            guard !trimmed.isEmpty else {
                rewrittenLines.append(line)
                continue
            }

            let kind: HLSRelayResourceKind = previousTag == "#EXT-X-STREAM-INF"
                || previousTag == "#EXT-X-I-FRAME-STREAM-INF"
                || trimmed.lowercased().contains(".m3u8")
                ? .playlist
                : .media
            let rewrittenURL = try resolvedRelayURL(
                for: trimmed,
                relativeTo: baseURL,
                kind: kind,
                relayURL: relayURL
            )
            let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
            rewrittenLines.append(String(leadingWhitespace) + rewrittenURL.absoluteString)
            previousTag = ""
        }

        // split(omittingEmptySubsequences: false) represents a trailing newline
        // as a final empty element, so joining already restores it.
        var result = rewrittenLines.joined(separator: "\n")
        if endsWithNewline && !result.hasSuffix("\n") {
            result.append("\n")
        }
        return Data(result.utf8)
    }

    private func rewriteAttributeURIs(
        in line: String,
        relativeTo baseURL: URL,
        relayURL: RelayURLProvider
    ) throws -> String {
        guard let colon = line.firstIndex(of: ":") else { return line }

        let prefix = String(line[...colon])
        let attributesStart = line.index(after: colon)
        let attributes = String(line[attributesStart...])
        let kind = resourceKind(forTag: tagName(in: line))

        let rewritten = try splitAttributes(attributes).map { attribute in
            try rewriteURIAttribute(
                attribute,
                relativeTo: baseURL,
                kind: kind,
                relayURL: relayURL
            )
        }
        return prefix + rewritten.joined(separator: ",")
    }

    private func rewriteURIAttribute(
        _ attribute: String,
        relativeTo baseURL: URL,
        kind: HLSRelayResourceKind,
        relayURL: RelayURLProvider
    ) throws -> String {
        guard let equals = attribute.firstIndex(of: "=") else { return attribute }
        let name = attribute[..<equals]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard name == "URI" || name.hasSuffix("-URI") else { return attribute }

        let valueStart = attribute.index(after: equals)
        let rawValue = String(attribute[valueStart...])
        let leading = rawValue.prefix { $0 == " " || $0 == "\t" }
        let trailing = rawValue.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        let quoted = trimmed.count >= 2 && trimmed.first == "\"" && trimmed.last == "\""
        let uri = quoted ? String(trimmed.dropFirst().dropLast()) : trimmed
        guard !uri.isEmpty else { return attribute }

        guard let target = try relayTarget(for: uri, relativeTo: baseURL) else {
            // Schemes such as data: and skd: are consumed by AVFoundation and
            // cannot be fetched by this HTTP relay.
            return attribute
        }
        let localURL = try relayURL(target, kind)
        let replacement = quoted ? "\"\(localURL.absoluteString)\"" : localURL.absoluteString
        return String(attribute[...equals]) + leading + replacement + trailing
    }

    private func resolvedRelayURL(
        for value: String,
        relativeTo baseURL: URL,
        kind: HLSRelayResourceKind,
        relayURL: RelayURLProvider
    ) throws -> URL {
        guard let target = try relayTarget(for: value, relativeTo: baseURL) else {
            throw HLSRelayError.invalidPlaylistURI
        }
        return try relayURL(target, kind)
    }

    private func relayTarget(for value: String, relativeTo baseURL: URL) throws -> URL? {
        guard let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw HLSRelayError.invalidPlaylistURI
        }
        guard let scheme = resolved.scheme?.lowercased() else {
            throw HLSRelayError.invalidPlaylistURI
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        guard resolved.host?.isEmpty == false else {
            throw HLSRelayError.invalidPlaylistURI
        }

        var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        guard let normalized = components?.url else {
            throw HLSRelayError.invalidPlaylistURI
        }
        return normalized
    }

    private func tagName(in line: String) -> String {
        let end = line.firstIndex(where: { $0 == ":" || $0 == " " || $0 == "\t" }) ?? line.endIndex
        return line[..<end].uppercased()
    }

    private func resourceKind(forTag tag: String) -> HLSRelayResourceKind {
        switch tag {
        case "#EXT-X-MEDIA",
             "#EXT-X-I-FRAME-STREAM-INF",
             "#EXT-X-IMAGE-STREAM-INF",
             "#EXT-X-RENDITION-REPORT":
            .playlist
        default:
            .media
        }
    }

    private func splitAttributes(_ value: String) -> [String] {
        var result: [String] = []
        var start = value.startIndex
        var index = start
        var insideQuotes = false

        while index < value.endIndex {
            let character = value[index]
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == "," && !insideQuotes {
                result.append(String(value[start..<index]))
                start = value.index(after: index)
            }
            index = value.index(after: index)
        }
        result.append(String(value[start...]))
        return result
    }
}
