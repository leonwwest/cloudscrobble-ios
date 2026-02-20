import CloudScrobbleCore
import SwiftUI

struct PlayerView: View {
    @ObservedObject var controller: PlayerScrobbleController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                nowPlayingCard
                queueCard
                debugCard
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Player")
        .cloudInlineNavigationTitle()
    }

    @ViewBuilder
    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now Playing")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.ink)

            switch controller.phase {
            case .idle:
                EmptyStateCard(
                    icon: "play.circle",
                    title: "No track loaded",
                    subtitle: "Start a track from Search or Library."
                )
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(CloudTheme.sky)
                    Text("Loading stream…")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(CloudTheme.muted)
                }
                .padding(4)
            case .failed(let message):
                Text(message)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(CloudTheme.warning)
            case .playing(let item), .paused(let item):
                HStack(spacing: 12) {
                    artwork(for: item)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .foregroundStyle(CloudTheme.ink)
                            .lineLimit(2)
                        Text(item.artistDisplay)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(CloudTheme.muted)
                        Text("Elapsed \(Int(controller.elapsedSeconds))s")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(CloudTheme.muted)
                    }
                }

                HStack(spacing: 8) {
                    Button("Previous") { controller.previous() }
                        .buttonStyle(SecondaryPillButtonStyle())
                    Button(isPlaying ? "Pause" : "Play") { controller.togglePlayback() }
                        .buttonStyle(PrimaryPillButtonStyle())
                    Button("Next") { controller.next() }
                        .buttonStyle(SecondaryPillButtonStyle())
                }
            }
        }
        .cloudCard()
    }

    @ViewBuilder
    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(CloudTheme.sky)
                Text("Queue")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.ink)
            }

            if controller.queue.isEmpty {
                Text("Queue is empty")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(CloudTheme.muted)
            } else {
                ForEach(Array(controller.queue.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(CloudTheme.ink)
                            Text(item.artistDisplay)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(CloudTheme.muted)
                        }
                        Spacer()
                        if controller.currentIndex == index {
                            Text("Current")
                                .font(.system(.caption2, design: .rounded).weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(CloudTheme.sky.opacity(0.18))
                                )
                                .foregroundStyle(CloudTheme.sky)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .cloudCard()
    }

    @ViewBuilder
    private var debugCard: some View {
        if !controller.debugStatus.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(controller.debugStatus)
                    .lineLimit(2)
            }
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(CloudTheme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.8))
            )
        }
    }

    private func artwork(for item: QueueItem) -> some View {
        AsyncImage(url: item.artworkURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(CloudTheme.sky.opacity(0.22))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(CloudTheme.sky)
                    )
            }
        }
        .frame(width: 86, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var isPlaying: Bool {
        if case .playing = controller.phase {
            return true
        }
        return false
    }
}

