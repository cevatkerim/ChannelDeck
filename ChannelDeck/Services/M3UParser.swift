import Foundation

struct M3UParser: Sendable {
    func parse(data: Data, baseURL: URL? = nil) throws -> ParsedPlaylist {
        guard var text = String(data: data, encoding: .utf8) else {
            throw ParserError.invalidTextEncoding
        }

        if text.first == "\u{feff}" {
            text.removeFirst()
        }

        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        guard let headerIndex = lines.firstIndex(where: { !$0.isEmpty }),
              lines[headerIndex].hasPrefix("#EXTM3U") else {
            throw ParserError.missingM3UHeader
        }

        let header = lines[headerIndex]
        let headerAttributes = Self.parseAttributes(
            in: String(header.dropFirst("#EXTM3U".count))
        )
        let title = Self.nonEmpty(headerAttributes["playlist-name"])
            ?? Self.nonEmpty(headerAttributes["name"])
        let epgURLs = Self.parseEPGURLs(
            headerAttributes["url-tvg"] ?? headerAttributes["x-tvg-url"],
            relativeTo: baseURL
        )

        var channels: [ParsedChannel] = []
        var pending: PendingChannel?
        var deferredGroup: String?

        for line in lines.dropFirst(headerIndex + 1) {
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXTINF:") {
                pending = Self.parseEXTINF(line, fallbackGroup: deferredGroup)
                deferredGroup = nil
                continue
            }

            if line.hasPrefix("#EXTGRP:") {
                let group = Self.nonEmpty(String(line.dropFirst("#EXTGRP:".count)))
                if pending != nil {
                    pending?.group = group
                } else {
                    deferredGroup = group
                }
                continue
            }

            if line.hasPrefix("#") {
                continue
            }

            guard let metadata = pending else {
                // Extended M3U requires a preceding EXTINF record. Ignoring an
                // orphan URI keeps one malformed row from hiding valid rows.
                continue
            }
            pending = nil

            guard let streamURL = Self.resolveURL(line, relativeTo: baseURL) else {
                continue
            }

            let channelName = Self.nonEmpty(metadata.name)
                ?? Self.nonEmpty(metadata.tvgName)
                ?? "Unnamed Channel"
            channels.append(
                ParsedChannel(
                    tvgID: Self.nonEmpty(metadata.tvgID),
                    tvgName: Self.nonEmpty(metadata.tvgName),
                    name: channelName,
                    group: Self.nonEmpty(metadata.group),
                    logoURL: metadata.logo.flatMap { Self.resolveURL($0, relativeTo: baseURL) },
                    streamURL: streamURL,
                    order: channels.count,
                    duration: metadata.duration
                )
            )
        }

        guard !channels.isEmpty else {
            throw ParserError.noPlayableChannels
        }

        return ParsedPlaylist(title: title, epgURLs: epgURLs, channels: channels)
    }

    private static func parseEXTINF(_ line: String, fallbackGroup: String?) -> PendingChannel {
        let body = String(line.dropFirst("#EXTINF:".count))
        let commaIndex = firstUnquotedComma(in: body)
        let metadata = commaIndex.map { String(body[..<$0]) } ?? body
        let displayName = commaIndex.map { String(body[body.index(after: $0)...]) } ?? ""
        let attributes = parseAttributes(in: metadata)
        let durationToken = metadata
            .trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            .first

        return PendingChannel(
            tvgID: attributes["tvg-id"],
            tvgName: attributes["tvg-name"],
            name: displayName,
            group: attributes["group-title"] ?? fallbackGroup,
            logo: attributes["tvg-logo"],
            duration: durationToken.flatMap { Int($0) }
        )
    }

    private static func firstUnquotedComma(in value: String) -> String.Index? {
        var quoted = false
        var escaped = false

        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" && quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == "," && !quoted {
                return index
            }
        }
        return nil
    }

    /// Parses both quoted and unquoted extended-M3U attributes without using
    /// a regex, so Unicode and escaped quotes remain intact.
    private static func parseAttributes(in value: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var index = value.startIndex

        while index < value.endIndex {
            while index < value.endIndex, value[index].isWhitespace {
                index = value.index(after: index)
            }
            let keyStart = index
            while index < value.endIndex, isAttributeKeyCharacter(value[index]) {
                index = value.index(after: index)
            }

            guard keyStart != index else {
                if index < value.endIndex { index = value.index(after: index) }
                continue
            }

            let key = String(value[keyStart..<index]).lowercased()
            let keyEnd = index
            while index < value.endIndex, value[index].isWhitespace {
                index = value.index(after: index)
            }
            guard index < value.endIndex, value[index] == "=" else {
                // EXTINF starts with a duration token (for example `-1`).
                // Rewind to the end of that token so the outer loop can skip
                // whitespace without also discarding the first real attribute.
                index = keyEnd
                continue
            }

            index = value.index(after: index)
            while index < value.endIndex, value[index].isWhitespace {
                index = value.index(after: index)
            }

            var parsedValue = ""
            if index < value.endIndex, value[index] == "\"" {
                index = value.index(after: index)
                var escaped = false
                while index < value.endIndex {
                    let character = value[index]
                    index = value.index(after: index)
                    if escaped {
                        parsedValue.append(character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        parsedValue.append(character)
                    }
                }
            } else {
                let valueStart = index
                while index < value.endIndex, !value[index].isWhitespace {
                    index = value.index(after: index)
                }
                parsedValue = String(value[valueStart..<index])
            }
            attributes[key] = parsedValue
        }

        return attributes
    }

    private static func isAttributeKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
    }

    private static func parseEPGURLs(_ value: String?, relativeTo baseURL: URL?) -> [URL] {
        guard let value else { return [] }
        var seen: Set<URL> = []
        return value
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { resolveURL(String($0), relativeTo: baseURL) }
            .filter { seen.insert($0).inserted }
    }

    private static func resolveURL(_ rawValue: String, relativeTo baseURL: URL?) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let baseURL {
            return URL(string: value, relativeTo: baseURL)?.absoluteURL
        }
        guard let url = URL(string: value), url.scheme != nil else { return nil }
        return url
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct PendingChannel {
    let tvgID: String?
    let tvgName: String?
    let name: String
    var group: String?
    let logo: String?
    let duration: Int?
}
