import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct XMLTVParser: Sendable {
    /// Parses programme records whose channel identifier exactly matches one of
    /// `channelIDs` and whose interval overlaps `timeWindow`.
    func parse(
        data: Data,
        channelIDs: Set<String>,
        timeWindow: Range<Date>
    ) throws -> [ParsedProgramme] {
        let delegate = XMLTVParserDelegate(
            channelIDs: channelIDs,
            timeWindow: timeWindow
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw ParserError.malformedXML
        }
        return delegate.programmes
    }
}

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private let channelIDs: Set<String>
    private let timeWindow: Range<Date>
    private let dateParser = XMLTVDateParser()

    private var builder: ProgrammeBuilder?
    private var activeField: TextField?
    private var textBuffer = ""

    private(set) var programmes: [ParsedProgramme] = []

    init(channelIDs: Set<String>, timeWindow: Range<Date>) {
        self.channelIDs = channelIDs
        self.timeWindow = timeWindow
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "programme":
            guard let channelID = attributeDict["channel"],
                  channelIDs.contains(channelID),
                  let startValue = attributeDict["start"],
                  let endValue = attributeDict["stop"],
                  let start = dateParser.date(from: startValue),
                  let end = dateParser.date(from: endValue),
                  start < end,
                  start < timeWindow.upperBound,
                  end > timeWindow.lowerBound else {
                builder = nil
                return
            }
            builder = ProgrammeBuilder(channelID: channelID, start: start, end: end)

        case "title":
            begin(.title)
        case "sub-title":
            begin(.subtitle)
        case "desc":
            begin(.description)
        case "category":
            begin(.category)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeField != nil else { return }
        textBuffer.append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard activeField != nil,
              let string = String(data: CDATABlock, encoding: .utf8) else {
            return
        }
        textBuffer.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if let field = TextField(elementName: elementName), activeField == field {
            finish(field)
            return
        }

        guard elementName == "programme", let builder else { return }
        programmes.append(builder.build())
        self.builder = nil
    }

    private func begin(_ field: TextField) {
        guard builder != nil else { return }
        activeField = field
        textBuffer = ""
    }

    private func finish(_ field: TextField) {
        defer {
            activeField = nil
            textBuffer = ""
        }
        guard builder != nil else { return }

        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch field {
        case .title:
            if builder?.title == nil { builder?.title = value }
        case .subtitle:
            if builder?.subtitle == nil { builder?.subtitle = value }
        case .description:
            if builder?.description == nil { builder?.description = value }
        case .category:
            builder?.categories.append(value)
        }
    }
}

private struct ProgrammeBuilder {
    let channelID: String
    let start: Date
    let end: Date
    var title: String?
    var subtitle: String?
    var description: String?
    var categories: [String] = []

    func build() -> ParsedProgramme {
        ParsedProgramme(
            channelID: channelID,
            title: title ?? "Untitled",
            subtitle: subtitle,
            description: description,
            categories: categories,
            start: start,
            end: end
        )
    }
}

private enum TextField: Equatable {
    case title
    case subtitle
    case description
    case category

    init?(elementName: String) {
        switch elementName {
        case "title": self = .title
        case "sub-title": self = .subtitle
        case "desc": self = .description
        case "category": self = .category
        default: return nil
        }
    }
}

private final class XMLTVDateParser {
    private let formatters: [DateFormatter]

    init() {
        let formats = [
            "yyyyMMddHHmmss Z",
            "yyyyMMddHHmm Z",
            "yyyyMMddHH Z",
            "yyyyMMdd Z",
            "yyyyMMddHHmmssZ",
            "yyyyMMddHHmmZ",
            "yyyyMMddHHZ",
            "yyyyMMddZ",
            "yyyyMMddHHmmss",
            "yyyyMMddHHmm",
            "yyyyMMddHH",
            "yyyyMMdd"
        ]
        formatters = formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            return formatter
        }
    }

    func date(from rawValue: String) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        for formatter in formatters {
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
