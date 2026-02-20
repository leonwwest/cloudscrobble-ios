import CloudScrobbleCore
import SwiftUI

struct PlayerView: View {
    @ObservedObject var controller: PlayerScrobbleController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now Playing")
                .font(.headline)

            switch controller.phase {
            case .idle:
                Text("No track loaded")
                    .foregroundStyle(.secondary)
            case .loading:
                ProgressView("Loading stream…")
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
            case .playing(let item), .paused(let item):
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.title3.bold())
                    Text(item.artistDisplay)
                        .foregroundStyle(.secondary)
                    Text("Elapsed: \(Int(controller.elapsedSeconds))s")
                        .font(.caption)

                    HStack(spacing: 10) {
                        Button("Previous") { controller.previous() }
                        Button(isPlaying ? "Pause" : "Play") { controller.togglePlayback() }
                        Button("Next") { controller.next() }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !controller.queue.isEmpty {
                Text("Queue")
                    .font(.subheadline.bold())

                List(Array(controller.queue.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Text(item.title)
                        Spacer()
                        if controller.currentIndex == index {
                            Text("Current")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !controller.debugStatus.isEmpty {
                Text(controller.debugStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isPlaying: Bool {
        if case .playing = controller.phase {
            return true
        }
        return false
    }
}
