import AVFoundation
import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(iOS) && canImport(UIKit)
import UIKit
#endif

/// Owns `MPNowPlayingInfoCenter` and lock-screen artwork loading. Extracted
/// from `PlayerScrobbleController` so artwork fetching and now-info publishing
/// are isolated from queue/scrobble logic.
///
/// Not an actor: accessed only from the `@MainActor` controller.
@MainActor
final class NowPlayingInfoCoordinator {
    /// Called after artwork finishes loading so the controller can re-publish
    /// now-playing info with the current playback position and rate.
    var refreshHandler: (() -> Void)?

#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackURN: String?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
#endif

    deinit {
#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
        artworkTask?.cancel()
#endif
    }

    func update(for item: QueueItem, elapsedSeconds: TimeInterval, playbackRate: Double) {
#if os(iOS) && canImport(MediaPlayer)
        prepareArtwork(for: item)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artistDisplay,
            MPMediaItemPropertyPlaybackDuration: Double(max(item.durationSeconds, 1)),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate
        ]

#if canImport(UIKit)
        if artworkTrackURN == item.trackURN, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
#endif

        if let permalinkURL = item.permalinkURL {
            info[MPNowPlayingInfoPropertyAssetURL] = permalinkURL
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
#endif
    }

    func clear() {
#if os(iOS) && canImport(MediaPlayer)
        clearArtwork()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
#endif
    }

    private func prepareArtwork(for item: QueueItem) {
#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
        guard artworkTrackURN != item.trackURN || artworkURL != item.artworkURL else {
            return
        }

        artworkTask?.cancel()
        artworkTrackURN = item.trackURN
        artworkURL = item.artworkURL
        artwork = nil

        guard let artworkURL = item.artworkURL else { return }

        artworkTask = Task { [weak self, trackURN = item.trackURN, artworkURL] in
            guard let loaded = await ArtworkImagePipeline.shared.image(
                for: artworkURL,
                maxPixelSize: 512
            ), !Task.isCancelled else {
                return
            }

            let artwork = Self.makeArtwork(from: loaded.image)
            guard let self,
                  self.artworkTrackURN == trackURN,
                  self.artworkURL == artworkURL else {
                return
            }

            self.artwork = artwork
            self.refreshHandler?()
        }
#endif
    }

    private func clearArtwork() {
#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
        artworkTask?.cancel()
        artworkTask = nil
        artworkTrackURN = nil
        artworkURL = nil
        artwork = nil
#endif
    }

#if os(iOS) && canImport(MediaPlayer) && canImport(UIKit)
    private nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
#endif
}
