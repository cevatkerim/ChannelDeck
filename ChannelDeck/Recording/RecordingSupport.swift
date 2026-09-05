import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BufferRecordingQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case sourceVideo
    case compatible

    static let defaultsKey = "bufferRecording.quality.v1"

    var id: Self { self }

    var title: String {
        switch self {
        case .sourceVideo: "Original Video"
        case .compatible: "Compatible 1080p"
        }
    }

    var compactTitle: String {
        switch self {
        case .sourceVideo: "Original"
        case .compatible: "Compatible"
        }
    }

    var systemImage: String {
        switch self {
        case .sourceVideo: "4k.tv"
        case .compatible: "tv"
        }
    }

    var guidance: String {
        switch self {
        case .sourceVideo:
            "Preserves the channel's source video resolution and HDR without re-encoding it. Audio is saved as AAC for reliable Apple playback. Uses more disk space, and older devices may not play every source codec."
        case .compatible:
            "Saves the AirPlay rendition as H.264/AAC at up to 1080p. It uses less disk space and plays on the widest range of Apple devices."
        }
    }

    static var savedDefault: Self {
        guard let value = UserDefaults.standard.string(forKey: defaultsKey),
              let quality = Self(rawValue: value) else {
            return .sourceVideo
        }
        return quality
    }
}

enum RecordingStorageError: Error, LocalizedError, Sendable {
    case applicationSupportUnavailable
    case invalidPackageName
    case invalidRecordingData

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "ChannelDeck could not access its recordings folder."
        case .invalidPackageName:
            "The selected recording package is not valid."
        case .invalidRecordingData:
            "The saved recording data could not be prepared for playback."
        }
    }
}

struct RecordingStorage: Sendable {
    static let packageExtension = "channeldeckrecording"
    static let playlistFileName = "index.m3u8"
    static let mediaFileName = "recording.ts"
    static let thumbnailFileName = "thumbnail.jpg"

    let rootURL: URL

    init(rootURL: URL? = nil) throws {
        if let rootURL {
            self.rootURL = rootURL.standardizedFileURL
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw RecordingStorageError.applicationSupportUnavailable
            }
            self.rootURL = applicationSupport
                .appendingPathComponent("ChannelDeck", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
                .standardizedFileURL
        }
    }

    func prepareRoot() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }

    func packageName(for id: UUID) -> String {
        "\(id.uuidString.lowercased()).\(Self.packageExtension)"
    }

    func newPackageURL(for id: UUID) throws -> URL {
        try prepareRoot()
        return rootURL.appendingPathComponent(packageName(for: id), isDirectory: true)
    }

    func packageURL(named packageName: String) throws -> URL {
        guard Self.isValidPackageName(packageName) else {
            throw RecordingStorageError.invalidPackageName
        }
        let result = rootURL.appendingPathComponent(packageName, isDirectory: true)
            .standardizedFileURL
        guard result.deletingLastPathComponent() == rootURL else {
            throw RecordingStorageError.invalidPackageName
        }
        return result
    }

    func playlistURL(inPackageNamed packageName: String) throws -> URL {
        try packageURL(named: packageName)
            .appendingPathComponent(Self.playlistFileName, isDirectory: false)
    }

    func mediaFileURL(inPackageNamed packageName: String) throws -> URL {
        try packageURL(named: packageName)
            .appendingPathComponent(Self.mediaFileName, isDirectory: false)
    }

    /// Returns a native local media file. Recordings created by older builds
    /// are migrated once by joining their validated MPEG-TS segments in the
    /// order declared by ChannelDeck's own media playlist.
    func playbackURL(inPackageNamed packageName: String) throws -> URL {
        let package = try packageURL(named: packageName)
        let mediaURL = package.appendingPathComponent(Self.mediaFileName, isDirectory: false)
        if Self.isNonemptyRegularFile(mediaURL) {
            return mediaURL
        }

        let legacyPlaylist = package.appendingPathComponent("media-0.m3u8", isDirectory: false)
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: legacyPlaylist.path
        ),
        let playlistSize = attributes[.size] as? NSNumber,
        playlistSize.int64Value > 0,
        playlistSize.int64Value <= 32 * 1_024 * 1_024,
        let playlist = try? String(contentsOf: legacyPlaylist, encoding: .utf8) else {
            throw RecordingStorageError.invalidRecordingData
        }

        let segmentNames = playlist
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !segmentNames.isEmpty,
              segmentNames.allSatisfy(Self.isSafeLegacySegmentName) else {
            throw RecordingStorageError.invalidRecordingData
        }

        let temporaryURL = package.appendingPathComponent(
            ".recording-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw RecordingStorageError.invalidRecordingData
        }
        do {
            for name in segmentNames {
                let segmentURL = package.appendingPathComponent(name, isDirectory: false)
                    .standardizedFileURL
                guard segmentURL.deletingLastPathComponent() == package,
                      Self.isNonemptyRegularFile(segmentURL) else {
                    throw RecordingStorageError.invalidRecordingData
                }
                try Self.appendContents(of: segmentURL, to: temporaryURL)
            }
            guard Self.isNonemptyRegularFile(temporaryURL) else {
                throw RecordingStorageError.invalidRecordingData
            }
            if FileManager.default.fileExists(atPath: mediaURL.path) {
                try FileManager.default.removeItem(at: mediaURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: mediaURL)
            return mediaURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func revealURL(inPackageNamed packageName: String) throws -> URL {
        let package = try packageURL(named: packageName)
        let mediaURL = package.appendingPathComponent(Self.mediaFileName, isDirectory: false)
        return Self.isNonemptyRegularFile(mediaURL) ? mediaURL : package
    }

    func thumbnailURL(
        inPackageNamed packageName: String,
        fileName: String?
    ) throws -> URL? {
        guard let fileName else { return nil }
        guard fileName == Self.thumbnailFileName else {
            throw RecordingStorageError.invalidPackageName
        }
        return try packageURL(named: packageName)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    func removePackage(named packageName: String) throws {
        let package = try packageURL(named: packageName)
        guard FileManager.default.fileExists(atPath: package.path) else { return }
        try FileManager.default.removeItem(at: package)
    }

    private static func isValidPackageName(_ value: String) -> Bool {
        let suffix = ".\(packageExtension)"
        guard value == URL(fileURLWithPath: value).lastPathComponent,
              value.lowercased().hasSuffix(suffix),
              let id = UUID(uuidString: String(value.dropLast(suffix.count))) else {
            return false
        }
        return value.caseInsensitiveCompare(
            "\(id.uuidString).\(packageExtension)"
        ) == .orderedSame
    }

    private static func isSafeLegacySegmentName(_ value: String) -> Bool {
        guard value.hasPrefix("segment-0-"), value.hasSuffix(".ts") else { return false }
        let sequence = value
            .dropFirst("segment-0-".count)
            .dropLast(".ts".count)
        return sequence.count == 9
            && sequence.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isNonemptyRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]) else { return false }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
    }

    private static func appendContents(of source: URL, to destination: URL) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        _ = try writer.seekToEnd()
        while let data = try reader.read(upToCount: 1_048_576), !data.isEmpty {
            try writer.write(contentsOf: data)
        }
    }
}

enum RecordingThumbnailGenerator {
    /// Extracts a representative frame after finalization. Thumbnail failure
    /// never invalidates a playable recording; the library falls back to the
    /// channel logo or a system placeholder.
    static func generate(for playlistURL: URL, in packageDirectory: URL) async -> String? {
        let asset = AVURLAsset(url: playlistURL)
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { return nil }
            let requestedSecond = min(max(duration * 0.33, 1), max(duration - 0.25, 0))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            let result = try await generator.image(
                at: CMTime(seconds: requestedSecond, preferredTimescale: 600)
            )
            let destinationURL = packageDirectory
                .appendingPathComponent(RecordingStorage.thumbnailFileName, isDirectory: false)
            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(
                destination,
                result.image,
                [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            return RecordingStorage.thumbnailFileName
        } catch {
            return nil
        }
    }
}
