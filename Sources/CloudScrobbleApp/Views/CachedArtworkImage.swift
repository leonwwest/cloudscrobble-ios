import Foundation
import ImageIO
import SwiftUI

#if os(iOS)
import UIKit
private typealias PlatformArtworkImage = UIImage
#elseif os(macOS)
import AppKit
private typealias PlatformArtworkImage = NSImage
#endif

@MainActor
private final class ArtworkMemoryCache {
    static let shared = ArtworkMemoryCache()

    private let cache = NSCache<NSURL, PlatformArtworkImage>()

    private init() {
        cache.countLimit = 360
    }

    func image(for url: URL) -> PlatformArtworkImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: PlatformArtworkImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

struct CachedArtworkImage: View {
    let url: URL?
    let iconName: String
    var maxPixelSize: CGFloat = 520

    @State private var image: PlatformArtworkImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            if let image {
                platformImage(image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(CloudTheme.elevatedStrong)
                    .overlay(
                        Image(systemName: iconName)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(CloudTheme.sky)
                    )
            }
        }
        .clipped()
        .task(id: url) {
            await loadImage()
        }
    }

    private func platformImage(_ image: PlatformArtworkImage) -> Image {
#if os(iOS)
        Image(uiImage: image)
#elseif os(macOS)
        Image(nsImage: image)
#endif
    }

    @MainActor
    private func loadImage() async {
        guard let url else {
            image = nil
            loadedURL = nil
            return
        }

        if loadedURL == url, image != nil {
            return
        }

        if let cached = ArtworkMemoryCache.shared.image(for: url) {
            image = cached
            loadedURL = url
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
                return
            }
            guard let decoded = Self.downsample(data: data, maxPixelSize: maxPixelSize) else {
                return
            }
            ArtworkMemoryCache.shared.insert(decoded, for: url)
            image = decoded
            loadedURL = url
        } catch {
            if loadedURL != url {
                image = nil
            }
        }
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> PlatformArtworkImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize)
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

#if os(iOS)
        return UIImage(cgImage: cgImage)
#elseif os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
#endif
    }
}
