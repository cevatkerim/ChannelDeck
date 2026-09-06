import CoreText
import CoreGraphics
import ImageIO
import Observation
import TVServices
import UIKit

/// Disk work, image decoding/compositing and logo downloads stay off the UI actor.
actor TVArtworkPipeline {
    let directory: URL
    private var index: [String: TVShelfArtwork]
    private var logos: [String: Data] = [:]
    private var logoAttempts: Set<String> = []
    private var shelf: [TVShelfEntry] = []
    private let loadLogo: @Sendable (URL) async throws -> Data
    init(directory: URL, loadLogo: @escaping @Sendable (URL) async throws -> Data = { try await TVHTTPClient().fetch($0, maximumBytes: 2 * 1024 * 1024) }) {
        self.loadLogo = loadLogo
        self.directory = directory
        index = (try? Data(contentsOf: directory.appending(path: "artwork.json")))
            .flatMap { try? JSONDecoder().decode([String: TVShelfArtwork].self, from: $0) } ?? [:]
    }
    func artwork(for key: String) -> TVShelfArtwork? { index[key] }
    func image(for key: String) -> Data? {
        try? migrate(key)
        guard let item = index[key], let url = TVShelfStore.imageURL(item.previewName(), directory: directory) else { return nil }
        return try? Data(contentsOf: url)
    }
    func publish(_ entries: [TVShelfEntry]) throws {
        shelf = entries
        for entry in entries { try migrate(entry.id) }
        try save()
    }
    private func migrate(_ key: String) throws {
        guard let old = index[key], old.style != TVShelfArtwork.currentStyle else { return }
        // Recompose raw frames, never the older JPEG containing a timestamp.
        let frame = old.capturedAt.flatMap { Date.now.timeIntervalSince($0) < 24 * 3600 ? try? Data(contentsOf: directory.appending(path: "frame-\(key).jpg")) : nil }
        try render(key: key, frame: frame, capturedAt: frame == nil ? nil : old.capturedAt, programmeTitle: nil)
    }
    func ensureLogo(_ channel: TVChannel) async {
        let key = TVShelfStore.key(channel.id)
        guard logoAttempts.insert(key).inserted else { return }
        if let url = channel.logoURL, let data = try? await loadLogo(url), Self.decode(data) != nil {
            logos[key] = data
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appending(path: "logo-\(key).data"), options: .atomic)
        }
        let frameURL = directory.appending(path: "frame-\(key).jpg")
        let frame = index[key]?.capturedAt.flatMap { Date.now.timeIntervalSince($0) < 24 * 3600 ? try? Data(contentsOf: frameURL) : nil }
        try? render(key: key, frame: frame, capturedAt: frame == nil ? nil : index[key]?.capturedAt, programmeTitle: index[key]?.programmeTitle)
        if logos.values.reduce(0, { $0 + $1.count }) > 16 * 1024 * 1024 { logos = logos.filter { $0.key == key } }
    }
    func store(_ data: Data, channel: TVChannel, capturedAt: Date, programmeTitle: String? = nil) throws {
        guard data.count < 1024 * 1024, Self.decode(data) != nil else { return }
        let key = TVShelfStore.key(channel.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "frame-\(key).jpg"), options: .atomic)
        let title = programmeTitle?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        try render(key: key, frame: data, capturedAt: capturedAt, programmeTitle: title?.isEmpty == false ? String(title!.prefix(512)) : nil)
    }
    private func render(key: String, frame: Data?, capturedAt: Date?, programmeTitle: String?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logo = logos[key] ?? (try? Data(contentsOf: directory.appending(path: "logo-\(key).data")))
        let version = UUID().uuidString
        let fallback = "\(key)-\(version)-logo.jpg"
        let image = frame == nil ? fallback : "\(key)-\(version).jpg"
        let title = frame == nil ? nil : programmeTitle
        let preview = title == nil ? image : "\(key)-\(version)-preview.jpg"
        try Self.compose(frame: nil, logo: logo, programmeTitle: nil).write(to: directory.appending(path: fallback), options: .atomic)
        if let frame {
            try Self.compose(frame: frame, logo: logo, programmeTitle: title).write(to: directory.appending(path: image), options: .atomic)
            if preview != image { try Self.compose(frame: frame, logo: logo, programmeTitle: nil).write(to: directory.appending(path: preview), options: .atomic) }
        }
        index[key] = TVShelfArtwork(image: image, fallback: fallback, capturedAt: capturedAt, preview: preview, programmeTitle: title, style: TVShelfArtwork.currentStyle)
        try save()
        try prune()
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: directory.appending(path: "artwork.json"), options: .atomic)
        let entries = shelf.map { TVShelfEntry(id: $0.id, name: $0.name, favorite: $0.favorite, artwork: index[$0.id]) }
        try JSONEncoder().encode(entries).write(to: directory.appending(path: "shelf.json"), options: .atomic)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
    private func prune() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { ["jpg", "data"].contains($0.pathExtension) }.compactMap { url -> (URL, Int, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
        let referenced = Set(index.values.flatMap { [$0.image, $0.fallback, $0.preview].compactMap { $0 } })
        var bytes = files.reduce(0) { $0 + $1.1 }
        for (url, size, date) in files {
            let age = Date.now.timeIntervalSince(date)
            if bytes > 64 * 1024 * 1024 || age > 48 * 3600 || (!referenced.contains(url.lastPathComponent) && !url.lastPathComponent.hasPrefix("frame-") && !url.lastPathComponent.hasPrefix("logo-") && age > 600) {
                try? FileManager.default.removeItem(at: url); bytes -= size
            }
        }
        // Cached media is disposable; retain only a bounded index as well.
        if index.count > 128 {
            let pinned = Set(shelf.map(\.id))
            let keep = pinned.union(index.filter { !pinned.contains($0.key) }.sorted { ($0.value.capturedAt ?? .distantPast) > ($1.value.capturedAt ?? .distantPast) }.prefix(max(0, 128 - pinned.count)).map(\.key))
            index = index.filter { keep.contains($0.key) }
            try save()
        }
    }
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary)
    }
    private static func compose(frame: Data?, logo: Data?, programmeTitle: String?) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw TVLibraryError.tooLarge }
        context.setFillColor(CGColor(red: 0.04, green: 0.14, blue: 0.11, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        if let frame, let image = decode(frame) { context.draw(image, in: CGRect(x: 0, y: 0, width: 640, height: 360)) }
        if let logo, let image = decode(logo) {
            let badge = frame == nil ? CGRect(x: 220, y: 112, width: 200, height: 136) : CGRect(x: 22, y: 262, width: 134, height: 76)
            context.setFillColor(CGColor(gray: 1, alpha: 0.94)); context.addPath(CGPath(roundedRect: badge, cornerWidth: 12, cornerHeight: 12, transform: nil)); context.fillPath()
            let scale = min((badge.width - 20) / CGFloat(image.width), (badge.height - 16) / CGFloat(image.height))
            let rect = CGRect(x: badge.midX - CGFloat(image.width) * scale / 2, y: badge.midY - CGFloat(image.height) * scale / 2, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.draw(image, in: rect)
        } else if frame == nil {
            context.setStrokeColor(CGColor(red: 0.57, green: 0.93, blue: 0.76, alpha: 0.8)); context.setLineWidth(8)
            context.addPath(CGPath(roundedRect: CGRect(x: 252, y: 134, width: 136, height: 92), cornerWidth: 12, cornerHeight: 12, transform: nil)); context.strokePath()
        }
        if frame != nil, let programmeTitle {
            // Home Screen images cannot host SwiftUI text. Use the system font,
            // safe insets and end truncation; in-app cards render native text.
            context.setFillColor(CGColor(gray: 0, alpha: 0.8)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 80))
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateUIFontForLanguage(.emphasizedSystem, 40, nil)!,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: programmeTitle, attributes: attributes))
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            let fitted = CTLineCreateTruncatedLine(line, 592, .end, ellipsis) ?? line
            context.textPosition = CGPoint(x: 24, y: 26); CTLineDraw(fitted, context)
        }
        let data = NSMutableData()
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw TVLibraryError.tooLarge }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TVLibraryError.tooLarge }
        return data as Data
    }
}

@MainActor @Observable
final class TVArtworkLibrary {
    private(set) var revision = 0
    let pipeline: TVArtworkPipeline
    private var requested: Set<String> = []
    private var pending: [TVChannel] = []
    private var workers = 0
    init(directory: URL? = nil) {
        pipeline = TVArtworkPipeline(directory: directory ?? TVShelfStore.directory ?? URL.cachesDirectory.appending(path: "ChannelDeckShelf"))
    }
    func updateShelf(_ channels: [TVChannel], favoriteIDs: Set<String>) async {
        let entries = channels.map { TVShelfEntry(id: TVShelfStore.key($0.id), name: $0.name, favorite: favoriteIDs.contains($0.preferenceID), artwork: nil) }
        try? await pipeline.publish(entries)
        // Only the short shelf is prefetched. Other logos load as cards appear.
        for channel in channels { ensure(channel) }
    }
    func ensure(_ channel: TVChannel) {
        guard requested.insert(channel.id).inserted else { return }
        pending.append(channel)
        startNext()
    }
    private func startNext() {
        guard workers < 3, !pending.isEmpty else { return }
        let channel = pending.removeFirst(); workers += 1
        Task {
            await pipeline.ensureLogo(channel)
            revision &+= 1; workers -= 1; startNext()
        }
    }
    func capture(_ data: Data, channel: TVChannel, capturedAt: Date, programmeTitle: String?) async {
        try? await pipeline.store(data, channel: channel, capturedAt: capturedAt, programmeTitle: programmeTitle)
        revision &+= 1
    }
}
