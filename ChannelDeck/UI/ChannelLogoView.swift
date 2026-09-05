import AppKit
import ImageIO
import SwiftUI

struct ChannelLogoView: View {
    let channel: ChannelRecord
    var size: CGFloat = 44

    @State private var loadedLogo: ChannelLogoImage?

    var body: some View {
        Group {
            if let loadedLogo {
                Image(
                    decorative: loadedLogo.cgImage,
                    scale: 1,
                    orientation: .up
                )
                .resizable()
                .scaledToFit()
                .padding(5)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
        .task(id: loadIdentifier) {
            loadedLogo = nil
            guard let url = channel.logoURL else { return }
            // Avoid starting downloads for rows that only flash through the
            // viewport during a fast scroll. SwiftUI cancels this task when
            // the row disappears, before any network or decoding work begins.
            do {
                try await Task.sleep(for: .milliseconds(90))
            } catch {
                return
            }
            let image = await ChannelLogoImageCache.shared.image(
                for: url,
                maximumPixelSize: maximumPixelSize
            )
            guard !Task.isCancelled else { return }
            loadedLogo = image
        }
    }

    private var maximumPixelSize: Int {
        // A 2x raster is sufficient for both Retina list rows and the detail
        // card. Downsampling before SwiftUI sees the logo avoids large source
        // images being decoded repeatedly while the list is scrolling.
        Int(max(32, min(512, (size * 2).rounded(.up))))
    }

    private var loadIdentifier: String {
        "\(channel.logoURL?.absoluteString ?? "fallback")#\(maximumPixelSize)"
    }

    private var fallback: some View {
        Text(channel.name.prefix(2).uppercased())
            .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
    }
}

/// A decoded thumbnail that may safely move from the cache actor to SwiftUI.
/// CGImage is immutable; the unchecked annotation only bridges older SDK
/// concurrency annotations that do not express that property.
private final class ChannelLogoImage: @unchecked Sendable {
    let cgImage: CGImage

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }
}

/// Shares downloads and decoded thumbnails across recycled List rows. NSCache
/// applies a strict memory/count bound and can discard entries under pressure.
private actor ChannelLogoImageCache {
    static let shared = ChannelLogoImageCache()

    private final class Entry: @unchecked Sendable {
        let image: ChannelLogoImage?
        let creationDate: Date

        init(image: ChannelLogoImage?, creationDate: Date = .now) {
            self.image = image
            self.creationDate = creationDate
        }
    }

    private static let maximumDownloadBytes = 8 * 1_024 * 1_024
    private static let failedEntryLifetime: TimeInterval = 5 * 60

    private let cache = NSCache<NSString, Entry>()

    init() {
        cache.countLimit = 512
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(for url: URL, maximumPixelSize: Int) async -> ChannelLogoImage? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              (16 ... 512).contains(maximumPixelSize) else {
            return nil
        }

        let key = "\(url.absoluteString)#\(maximumPixelSize)"
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            if cached.image != nil
                || Date().timeIntervalSince(cached.creationDate) < Self.failedEntryLifetime {
                return cached.image
            }
            cache.removeObject(forKey: cacheKey)
        }

        do {
            var request = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 15
            )
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode),
                  !data.isEmpty,
                  data.count <= Self.maximumDownloadBytes,
                  let decoded = Self.downsample(data, maximumPixelSize: maximumPixelSize) else {
                return cache(Entry(image: nil), for: cacheKey)
            }
            try Task.checkCancellation()
            return cache(Entry(image: ChannelLogoImage(decoded)), for: cacheKey)
        } catch is CancellationError {
            // Cancellation means the row left the viewport; do not poison the
            // failure cache, because the same logo may be requested later.
            return nil
        } catch {
            return cache(Entry(image: nil), for: cacheKey)
        }
    }

    @discardableResult
    private func cache(_ entry: Entry, for key: NSString) -> ChannelLogoImage? {
        let cost: Int
        if let image = entry.image?.cgImage {
            cost = image.bytesPerRow * image.height
        } else {
            cost = 1
        }
        cache.setObject(entry, forKey: key, cost: cost)
        return entry.image
    }

    private nonisolated static func downsample(
        _ data: Data,
        maximumPixelSize: Int
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
