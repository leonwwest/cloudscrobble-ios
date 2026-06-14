import CloudScrobbleCore
import Foundation
import SwiftUI

struct PlayerView: View {
    @ObservedObject var session: AppSessionViewModel
    @ObservedObject private var controller: PlayerScrobbleController

    @State private var isSeeking = false
    @State private var seekValue: Double = 0

    init(session: AppSessionViewModel) {
        self.session = session
        self.controller = session.playerController
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                nowPlayingCard
                queueCard
                recentlyPlayedCard
                scrobbleHistoryCard
                debugCard
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 84)
        }
    }

    @ViewBuilder
    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Now Playing")
                .font(.system(.title3, design: .rounded).weight(.black))
                .foregroundStyle(CloudTheme.ink)

            switch controller.phase {
            case .idle:
                VStack(spacing: 10) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(CloudTheme.sky)
                    Text("No track loaded")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(CloudTheme.ink)
                    Text("Start a track from Search or Library.")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(CloudTheme.sky)
                    Text("Loading stream…")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                }
                .padding(4)
            case .failed(let message):
                Text(message)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.warning)
            case .playing(let item), .paused(let item):
                VStack(alignment: .leading, spacing: 14) {
                    artwork(for: item)
                        .frame(maxWidth: .infinity, alignment: .center)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(.title3, design: .rounded).weight(.black))
                            .foregroundStyle(CloudTheme.ink)
                            .lineLimit(2)
                        Text(item.artistDisplay)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(CloudTheme.muted)
                    }

                    Slider(
                        value: Binding(
                            get: {
                                isSeeking ? seekValue : min(controller.elapsedSeconds, Double(max(item.durationSeconds, 1)))
                            },
                            set: { newValue in
                                seekValue = newValue
                            }
                        ),
                        in: 0...Double(max(item.durationSeconds, 1)),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if !editing {
                                controller.seek(to: seekValue)
                            }
                        }
                    )
                        .tint(CloudTheme.sky)
                    HStack {
                        Text(timeLabel(isSeeking ? seekValue : controller.elapsedSeconds))
                        Spacer()
                        Text(timeLabel(Double(item.durationSeconds)))
                    }
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.muted)

                    HStack(spacing: 10) {
                        Button {
                            controller.seek(to: max(0, controller.elapsedSeconds - 15))
                        } label: {
                            Label("Back 15", systemImage: "gobackward.15")
                        }
                        .buttonStyle(PlayerModeButtonStyle(isActive: false))

                        Spacer(minLength: 8)

                        Button {
                            controller.seek(to: min(Double(item.durationSeconds), controller.elapsedSeconds + 15))
                        } label: {
                            Label("Forward 15", systemImage: "goforward.15")
                        }
                        .buttonStyle(PlayerModeButtonStyle(isActive: false))
                    }

                    HStack(spacing: 18) {
                        Spacer()
                        Button { controller.previous() } label: {
                            Image(systemName: "backward.fill")
                        }
                        .buttonStyle(IconCircleButtonStyle())

                        Button { controller.togglePlayback() } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(IconCircleButtonStyle(isPrimary: true))

                        Button { controller.next() } label: {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(IconCircleButtonStyle())
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button { controller.toggleShuffle() } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        .buttonStyle(PlayerModeButtonStyle(isActive: controller.isShuffleEnabled))

                        Spacer(minLength: 8)

                        Text(queuePositionLabel)
                            .font(.system(.caption2, design: .rounded).weight(.bold))
                            .foregroundStyle(CloudTheme.muted)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Button { controller.cycleRepeatMode() } label: {
                            Label(repeatModeTitle, systemImage: repeatModeIcon)
                        }
                        .buttonStyle(PlayerModeButtonStyle(isActive: controller.repeatMode != .off))
                    }
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
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                Spacer()
                if !controller.queue.isEmpty {
                    Button {
                        controller.clearQueue()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(IconCircleButtonStyle())
                    .accessibilityLabel("Clear queue")
                }
            }

            if controller.queue.isEmpty {
                Text("Queue is empty")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
            } else {
                ForEach(Array(controller.queue.enumerated()), id: \.element.id) { index, item in
                    QueueItemRow(
                        item: item,
                        isCurrent: controller.currentIndex == index,
                        canMoveUp: index > 0,
                        canMoveDown: index < controller.queue.count - 1,
                        onPlay: { controller.playQueueItem(at: index) },
                        onMoveUp: { controller.moveQueueItem(from: index, to: index - 1) },
                        onMoveDown: { controller.moveQueueItem(from: index, to: index + 1) },
                        onRemove: { controller.removeQueueItem(at: index) }
                    )
                }
            }
        }
        .cloudCard()
    }

    @ViewBuilder
    private var recentlyPlayedCard: some View {
        if !controller.recentlyPlayed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(CloudTheme.sky)
                    Text("Recently Played")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(CloudTheme.ink)
                    Spacer()
                    Button {
                        controller.clearRecentlyPlayed()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconCircleButtonStyle())
                    .accessibilityLabel("Clear recently played")
                }

                ForEach(controller.recentlyPlayed.prefix(12)) { track in
                    RecentlyPlayedRow(track: track) {
                        Task { await session.play(savedTrack: track) }
                    }
                }
            }
            .cloudCard()
        }
    }

    @ViewBuilder
    private var debugCard: some View {
        if hasLastFMStatus {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(CloudTheme.sky)
                    Text("Last.fm Status")
                        .font(.system(.caption, design: .rounded).weight(.black))
                        .foregroundStyle(CloudTheme.ink)
                }

                if !controller.debugStatus.isEmpty {
                    Text(controller.debugStatus)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                        .lineLimit(3)
                }

                if controller.pendingScrobbleCount > 0 {
                    Text("\(controller.pendingScrobbleCount) pending scrobbles")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.warning)
                        .lineLimit(1)
                }

                if let lastScrobbleSucceededAt = controller.lastScrobbleSucceededAt {
                    Text("Last scrobble \(lastFMDateText(lastScrobbleSucceededAt))")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                        .lineLimit(1)
                }

                if let lastScrobbleError = controller.lastScrobbleError {
                    Text(lastScrobbleError)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.warning)
                        .lineLimit(3)
                }

                if controller.skippedUnplayableCount > 0 {
                    Text("\(controller.skippedUnplayableCount) unplayable track\(controller.skippedUnplayableCount == 1 ? "" : "s") skipped")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.warning)
                        .lineLimit(2)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CloudTheme.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(CloudTheme.line, lineWidth: 1)
            )
        }
    }

    private var hasLastFMStatus: Bool {
        !controller.debugStatus.isEmpty
            || controller.pendingScrobbleCount > 0
            || controller.lastScrobbleSucceededAt != nil
            || controller.lastScrobbleError != nil
            || controller.skippedUnplayableCount > 0
    }

    @ViewBuilder
    private var scrobbleHistoryCard: some View {
        if !controller.scrobbleHistory.isEmpty || controller.skippedUnplayableCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "list.bullet.clipboard")
                        .foregroundStyle(CloudTheme.sky)
                    Text("Scrobble Verlauf")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(CloudTheme.ink)

                    Spacer()

                    if !controller.scrobbleHistory.isEmpty {
                        Button {
                            controller.clearScrobbleHistory()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(IconCircleButtonStyle())
                        .accessibilityLabel("Clear scrobble history")
                    }
                }

                if controller.scrobbleHistory.isEmpty {
                    Text("Noch keine Last.fm Events in dieser Installation.")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                } else {
                    ForEach(controller.scrobbleHistory.prefix(20)) { entry in
                        ScrobbleHistoryRow(entry: entry)
                    }
                }
            }
            .cloudCard()
        }
    }

    private func artwork(for item: QueueItem, size: CGFloat = 184) -> some View {
        CachedArtworkImage(url: item.artworkURL, iconName: "music.note")
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(CloudTheme.line, lineWidth: 1)
        )
    }

    private var isPlaying: Bool {
        if case .playing = controller.phase {
            return true
        }
        return false
    }

    private var queuePositionLabel: String {
        guard let currentIndex = controller.currentIndex, !controller.queue.isEmpty else {
            return "Queue empty"
        }
        return "\(currentIndex + 1) of \(controller.queue.count)"
    }

    private var repeatModeIcon: String {
        switch controller.repeatMode {
        case .off, .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatModeTitle: String {
        switch controller.repeatMode {
        case .off:
            return "Repeat"
        case .all:
            return "All"
        case .one:
            return "One"
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let clamped = max(0, Int(seconds))
        return "\(clamped / 60):\(String(format: "%02d", clamped % 60))"
    }

    private func lastFMDateText(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct QueueItemRow: View {
    let item: QueueItem
    let isCurrent: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onPlay: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 10) {
                    queueArtwork

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(CloudTheme.ink)
                            .lineLimit(1)
                        Text(item.artistDisplay)
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(CloudTheme.muted)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(CloudTheme.sky.opacity(0.18)))
                    .foregroundStyle(CloudTheme.sky)
            }

            HStack(spacing: 4) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .disabled(!canMoveUp)
                .opacity(canMoveUp ? 1 : 0.35)
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel("Move up")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .disabled(!canMoveDown)
                .opacity(canMoveDown ? 1 : 0.35)
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel("Move down")

                Button(action: onRemove) {
                    Image(systemName: "minus")
                }
                .buttonStyle(IconCircleButtonStyle())
                .accessibilityLabel("Remove from queue")
            }
        }
        .padding(.vertical, 6)
    }

    private var queueArtwork: some View {
        CachedArtworkImage(url: item.artworkURL, iconName: "music.note", maxPixelSize: 160)
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct RecentlyPlayedRow: View {
    let track: SavedPlaybackTrack
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            CachedArtworkImage(url: track.artworkURL, iconName: "clock", maxPixelSize: 160)
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(1)
                Text(track.artistDisplay)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(CloudTheme.sky))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title)")
        }
        .padding(.vertical, 5)
    }
}

private struct ScrobbleHistoryRow: View {
    let entry: ScrobbleHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(Circle().fill(color.opacity(0.15)))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.ink)
                    .lineLimit(1)
                Text(detailText)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            Text(entry.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(CloudTheme.muted)
        }
        .padding(.vertical, 4)
    }

    private var detailText: String {
        var value = "\(entry.artist) - \(eventTitle)"
        if let message = entry.message, !message.isEmpty {
            value += " - \(message)"
        }
        return value
    }

    private var eventTitle: String {
        switch entry.event {
        case .nowPlaying:
            return "Now Playing"
        case .scrobbled:
            return "Gesendet"
        case .queued:
            return "Queued"
        case .failed:
            return "Fehler"
        case .skipped:
            return "Skipped"
        }
    }

    private var iconName: String {
        switch entry.event {
        case .nowPlaying:
            return "dot.radiowaves.left.and.right"
        case .scrobbled:
            return "checkmark.circle.fill"
        case .queued:
            return "tray.and.arrow.down.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .skipped:
            return "forward.end.fill"
        }
    }

    private var color: Color {
        switch entry.event {
        case .nowPlaying:
            return CloudTheme.sky
        case .scrobbled:
            return CloudTheme.success
        case .queued:
            return CloudTheme.amber
        case .failed, .skipped:
            return CloudTheme.warning
        }
    }
}

private struct PlayerModeButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, design: .rounded).weight(.bold))
            .foregroundStyle(isActive ? .white : CloudTheme.ink)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(minWidth: 92)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? CloudTheme.sky : CloudTheme.elevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0.18 : 0.10), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
