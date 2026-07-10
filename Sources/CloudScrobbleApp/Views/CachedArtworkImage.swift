import CloudScrobbleCore
import Foundation
import SwiftUI

#if os(iOS)
import UIKit
private typealias PlatformArtworkImage = UIImage
#elseif os(macOS)
import AppKit
private typealias PlatformArtworkImage = NSImage
#endif

struct CachedArtworkImage: View {
    let url: URL?
    let iconName: String
    var maxPixelSize: CGFloat = 512

    @State private var image: PlatformArtworkImage?
    @State private var loadedRequestID: String?

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
        .task(id: requestID) {
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
        guard let url, let requestID else {
            image = nil
            loadedRequestID = nil
            return
        }

        if loadedRequestID == requestID, image != nil {
            return
        }

        image = nil
        let loaded = await ArtworkImagePipeline.shared.image(
            for: url,
            maxPixelSize: maxPixelSize
        )
        guard !Task.isCancelled, self.requestID == requestID else { return }
        image = loaded?.image
        loadedRequestID = loaded == nil ? nil : requestID
    }

    private var requestID: String? {
        guard let url else { return nil }
        return "\(url.absoluteString)#px=\(Int(ceil(maxPixelSize)))"
    }
}
