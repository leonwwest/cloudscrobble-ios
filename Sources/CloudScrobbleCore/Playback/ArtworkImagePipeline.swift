import Foundation
import ImageIO

#if os(iOS)
import UIKit
public typealias ArtworkPlatformImage = UIImage
#elseif os(macOS)
import AppKit
public typealias ArtworkPlatformImage = NSImage
#endif

/// A decoded, downsampled artwork image that can safely cross concurrency
/// boundaries. UIKit/AppKit image objects are immutable after construction in
/// this pipeline.
public struct LoadedArtworkImage: @unchecked Sendable {
    public let image: ArtworkPlatformImage

    fileprivate let cost: Int
}

/// Shared artwork loading for both SwiftUI artwork and lock-screen artwork.
/// Requests are keyed by URL and a bounded pixel-size bucket, downloads and
/// decodes are coalesced, and all ImageIO work happens away from the main actor.
public actor ArtworkImagePipeline {
    public static let shared = ArtworkImagePipeline()

    private struct Download {
        let id: UUID
        let task: Task<Data?, Never>
    }

    private let cache = NSCache<NSString, ArtworkPlatformImage>()
    private var downloads: [URL: Download] = [:]
    private var decodes: [String: Task<LoadedArtworkImage?, Never>] = [:]

    public init() {
        cache.countLimit = 360
#if os(iOS)
        cache.totalCostLimit = 64 * 1_024 * 1_024
#else
        cache.totalCostLimit = 96 * 1_024 * 1_024
#endif
    }

    public func image(for url: URL, maxPixelSize: CGFloat) async -> LoadedArtworkImage? {
        let bucket = Self.pixelSizeBucket(for: maxPixelSize)
        let key = Self.cacheKey(url: url, bucket: bucket)

        if let cached = cache.object(forKey: key as NSString) {
            return LoadedArtworkImage(image: cached, cost: 0)
        }

        if let existingDecode = decodes[key] {
            return await existingDecode.value
        }

        let download: Download
        if let existingDownload = downloads[url] {
            download = existingDownload
        } else {
            let id = UUID()
            let task = Task.detached(priority: .utility) { () -> Data? in
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 30

                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard !Task.isCancelled,
                          (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else {
                        return nil
                    }
                    return data
                } catch {
                    return nil
                }
            }
            download = Download(id: id, task: task)
            downloads[url] = download
        }

        let decodeTask = Task.detached(priority: .utility) { () -> LoadedArtworkImage? in
            guard !Task.isCancelled,
                  let data = await download.task.value else {
                return nil
            }
            return Self.downsample(data: data, maxPixelSize: bucket)
        }
        decodes[key] = decodeTask

        let decoded = await decodeTask.value
        decodes[key] = nil
        if downloads[url]?.id == download.id {
            downloads[url] = nil
        }

        if let decoded {
            cache.setObject(decoded.image, forKey: key as NSString, cost: decoded.cost)
        }
        return decoded
    }

    nonisolated static func pixelSizeBucket(for requestedSize: CGFloat) -> Int {
        let requested = max(1, Int(ceil(requestedSize)))
        let buckets = [96, 160, 256, 512, 768, 1_024]
        return buckets.first(where: { $0 >= requested }) ?? 1_536
    }

    private nonisolated static func cacheKey(url: URL, bucket: Int) -> String {
        "\(url.absoluteString)#px=\(bucket)"
    }

    private nonisolated static func downsample(data: Data, maxPixelSize: Int) -> LoadedArtworkImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard !Task.isCancelled,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        let cost = max(1, cgImage.bytesPerRow * cgImage.height)
#if os(iOS)
        return LoadedArtworkImage(image: UIImage(cgImage: cgImage), cost: cost)
#elseif os(macOS)
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return LoadedArtworkImage(image: NSImage(cgImage: cgImage, size: size), cost: cost)
#endif
    }
}
