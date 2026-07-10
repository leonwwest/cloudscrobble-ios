import CloudScrobbleCore
import Foundation
import SwiftUI
#if os(iOS)
import AVKit
import UIKit
#endif

struct PlayerView: View {
    @ObservedObject var session: AppSessionViewModel
    @ObservedObject private var controller: PlayerScrobbleController

    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var showDiagnosticsSheet = false
    @State private var scrobbleEditor: ScrobbleEditorPayload?
    @State private var showClearQueueConfirmation = false
    @State private var showClearRecentConfirmation = false

    init(session: AppSessionViewModel) {
        self.session = session
        self.controller = session.playerController
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                nowPlayingCard
                scrobbleSummaryCard
                queueCard
                recentlyPlayedCard
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 84)
        }
        .sheet(isPresented: $showDiagnosticsSheet) {
            ScrobbleDiagnosticsView(controller: controller) {
                Task { await controller.refreshLastFMDiagnostics() }
            }
        }
        .sheet(item: $scrobbleEditor) { payload in
            ScrobbleMetadataEditor(
                payload: payload,
                onSave: { artist, track, isTrackEnabled, isArtistExcluded in
                    await session.saveScrobbleConfiguration(
                        for: payload.item,
                        artist: artist,
                        track: track,
                        isTrackEnabled: isTrackEnabled,
                        isArtistExcluded: isArtistExcluded
                    )
                },
                onReset: {
                    await session.resetScrobbleConfiguration(for: payload.item)
                }
            )
        }
        .confirmationDialog(
            "Clear the entire queue?",
            isPresented: $showClearQueueConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear queue", role: .destructive) { controller.clearQueue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Current playback and the saved queue will be removed.")
        }
        .confirmationDialog(
            "Clear recently played?",
            isPresented: $showClearRecentConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear recently played", role: .destructive) { controller.clearRecentlyPlayed() }
            Button("Cancel", role: .cancel) {}
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

                    HStack(spacing: 8) {
                        if !item.scrobbleEnabled {
                            Label("Scrobbling off", systemImage: "dot.radiowaves.left.and.right.slash")
                                .font(.system(.caption, design: .rounded).weight(.bold))
                                .foregroundStyle(CloudTheme.warning)
                        }
                        Spacer(minLength: 4)
                        Button {
                            Task {
                                let configuration = await session.scrobbleConfiguration(for: item)
                                scrobbleEditor = ScrobbleEditorPayload(item: item, configuration: configuration)
                            }
                        } label: {
                            Label("Edit scrobble", systemImage: "pencil")
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
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
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(
                            "\(timeLabel(isSeeking ? seekValue : controller.elapsedSeconds)) of \(timeLabel(Double(item.durationSeconds)))"
                        )
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
                        .accessibilityLabel("Previous track")

                        Button { controller.togglePlayback() } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(IconCircleButtonStyle(isPrimary: true))
                        .accessibilityLabel(isPlaying ? "Pause" : "Play")

                        Button { controller.next() } label: {
                            Image(systemName: "forward.fill")
                        }
                        .buttonStyle(IconCircleButtonStyle())
                        .accessibilityLabel("Next track")
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

                    HStack(spacing: 10) {
                        Menu {
                            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                                Button("\(minutes) minutes") {
                                    controller.startSleepTimer(minutes: minutes)
                                }
                            }
                            if controller.sleepTimerEndsAt != nil {
                                Divider()
                                Button("Cancel sleep timer", role: .destructive) {
                                    controller.cancelSleepTimer()
                                }
                            }
                        } label: {
                            Label(sleepTimerTitle, systemImage: "moon.zzz.fill")
                        }
                        .buttonStyle(PlayerModeButtonStyle(isActive: controller.sleepTimerEndsAt != nil))

                        Spacer()

#if os(iOS)
                        AirPlayRoutePickerButton()
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(CloudTheme.elevated))
                            .clipShape(Circle())
                            .accessibilityLabel("Choose audio output")
#endif
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
                        showClearQueueConfirmation = true
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
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(controller.queue.enumerated()), id: \.offset) { index, item in
                        QueueItemRow(
                            item: item,
                            dragIdentifier: String(index),
                            isCurrent: controller.currentIndex == index,
                            canMoveUp: index > 0,
                            canMoveDown: index < controller.queue.count - 1,
                            onPlay: { controller.playQueueItem(at: index) },
                            onMoveUp: { controller.moveQueueItem(from: index, to: index - 1) },
                            onMoveDown: { controller.moveQueueItem(from: index, to: index + 1) },
                            onRemove: { controller.removeQueueItem(at: index) }
                        )
                        .dropDestination(for: String.self) { identifiers, _ in
                            guard let sourceIdentifier = identifiers.first else { return false }
                            return reorderQueue(sourceIdentifier: sourceIdentifier, targetIndex: index)
                        }
                    }
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
                        showClearRecentConfirmation = true
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

    private var scrobbleSummaryCard: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: scrobbleStatusIcon)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(scrobbleStatusColor)
                .frame(width: 42, height: 42)
                .background(Circle().fill(scrobbleStatusColor.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text("Last.fm")
                    .font(.system(.headline, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                Text(scrobbleStatusText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button {
                showDiagnosticsSheet = true
            } label: {
                Label("Details", systemImage: "list.bullet.clipboard")
            }
            .buttonStyle(SecondaryPillButtonStyle())
        }
        .cloudCard()
    }

    private func artwork(for item: QueueItem, size: CGFloat = 184) -> some View {
        CachedArtworkImage(url: item.artworkURL, iconName: "music.note", maxPixelSize: 512)
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

    private var sleepTimerTitle: String {
        guard let endDate = controller.sleepTimerEndsAt else { return "Sleep timer" }
        return "Until \(endDate.formatted(date: .omitted, time: .shortened))"
    }

    private func reorderQueue(sourceIdentifier: String, targetIndex: Int) -> Bool {
        guard let sourceIndex = Int(sourceIdentifier),
              controller.queue.indices.contains(sourceIndex),
              controller.queue.indices.contains(targetIndex),
              sourceIndex != targetIndex else {
            return false
        }
        controller.moveQueueItem(from: sourceIndex, to: targetIndex)
        return true
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

    private var scrobbleStatusText: String {
        if !session.lastFMConnected {
            return "Off. Connect Last.fm to send Now Playing and scrobbles."
        }
        if let lastScrobbleError = controller.lastScrobbleError, !lastScrobbleError.isEmpty {
            return "Needs attention. Details explain the Last.fm error."
        }
        if controller.pendingScrobbleCount > 0 {
            return "\(controller.pendingScrobbleCount) queued for retry."
        }
        if let lastScrobbleSucceededAt = controller.lastScrobbleSucceededAt {
            return "Last scrobble \(lastFMDateText(lastScrobbleSucceededAt))."
        }
        if !controller.debugStatus.isEmpty {
            return controller.debugStatus
        }
        return "Ready. Tracks scrobble after the listening threshold."
    }

    private var scrobbleStatusIcon: String {
        if !session.lastFMConnected {
            return "bolt.slash.fill"
        }
        if controller.lastScrobbleError != nil {
            return "exclamationmark.triangle.fill"
        }
        if controller.pendingScrobbleCount > 0 {
            return "tray.and.arrow.down.fill"
        }
        if controller.lastScrobbleSucceededAt != nil {
            return "checkmark.circle.fill"
        }
        return "dot.radiowaves.left.and.right"
    }

    private var scrobbleStatusColor: Color {
        if !session.lastFMConnected {
            return CloudTheme.muted
        }
        if controller.lastScrobbleError != nil || controller.pendingScrobbleCount > 0 {
            return CloudTheme.warning
        }
        if controller.lastScrobbleSucceededAt != nil {
            return CloudTheme.success
        }
        return CloudTheme.sky
    }
}

private struct QueueItemRow: View {
    let item: QueueItem
    let dragIdentifier: String
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
                Image(systemName: "line.3.horizontal")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(CloudTheme.muted)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                    .draggable(dragIdentifier)
                    .accessibilityLabel("Drag to reorder")

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

private struct ScrobbleEditorPayload: Identifiable {
    let item: QueueItem
    let configuration: ScrobbleTrackConfiguration

    var id: String { item.trackURN }
}

private struct ScrobbleMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss

    let payload: ScrobbleEditorPayload
    let onSave: (_ artist: String, _ track: String, _ isTrackEnabled: Bool, _ isArtistExcluded: Bool) async -> Void
    let onReset: () async -> Void

    @State private var artist: String
    @State private var track: String
    @State private var isTrackEnabled: Bool
    @State private var isArtistExcluded: Bool
    @State private var isSaving = false
    @State private var showResetConfirmation = false

    init(
        payload: ScrobbleEditorPayload,
        onSave: @escaping (_ artist: String, _ track: String, _ isTrackEnabled: Bool, _ isArtistExcluded: Bool) async -> Void,
        onReset: @escaping () async -> Void
    ) {
        self.payload = payload
        self.onSave = onSave
        self.onReset = onReset
        _artist = State(initialValue: payload.configuration.metadata.artist)
        _track = State(initialValue: payload.configuration.metadata.track)
        _isTrackEnabled = State(initialValue: !payload.configuration.isTrackExcluded)
        _isArtistExcluded = State(initialValue: payload.configuration.isArtistExcluded)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Artist", text: $artist)
                        .textContentType(.organizationName)
                    TextField("Track title", text: $track)
                } header: {
                    Text("Last.fm metadata")
                } footer: {
                    Text("These values are saved for this SoundCloud track and used for future scrobbles.")
                }

                Section("Scrobbling") {
                    Toggle("Scrobble this track", isOn: $isTrackEnabled)
                    Toggle("Exclude this artist", isOn: $isArtistExcluded)

                    Label(effectiveScrobbleStatus, systemImage: effectiveScrobbleIcon)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(effectiveScrobbleColor)
                }

                Section {
                    Button("Restore automatic metadata", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .disabled(isSaving)
                } footer: {
                    Text("Reset removes the correction and both exclusions. It cannot undo scrobbles already sent to Last.fm.")
                }
            }
            .navigationTitle("Edit scrobble")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isSaving = true
                            await onSave(trimmedArtist, trimmedTrack, isTrackEnabled, isArtistExcluded)
                            dismiss()
                        }
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Save")
                                .fontWeight(.bold)
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .confirmationDialog(
                "Restore automatic scrobble settings?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore automatic settings", role: .destructive) {
                    Task {
                        isSaving = true
                        await onReset()
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your metadata correction and exclusions for this track will be removed.")
            }
        }
    }

    private var trimmedArtist: String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTrack: String {
        track.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !isSaving && !trimmedArtist.isEmpty && !trimmedTrack.isEmpty
    }

    private var effectiveScrobbleStatus: String {
        if isArtistExcluded {
            return "All tracks by this artist will be excluded"
        }
        if !isTrackEnabled {
            return "This track will not be scrobbled"
        }
        return "Scrobbling is enabled"
    }

    private var effectiveScrobbleIcon: String {
        isArtistExcluded || !isTrackEnabled
            ? "dot.radiowaves.left.and.right.slash"
            : "checkmark.circle.fill"
    }

    private var effectiveScrobbleColor: Color {
        isArtistExcluded || !isTrackEnabled ? CloudTheme.warning : CloudTheme.success
    }
}

#if os(iOS)
private struct AirPlayRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.prioritizesVideoDevices = false
        picker.tintColor = .systemBlue
        picker.activeTintColor = .systemBlue
        picker.isAccessibilityElement = true
        picker.accessibilityLabel = "Choose audio output"
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

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

private struct PlayerModeButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .frame(minWidth: 92, minHeight: 44)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? CloudTheme.sky : CloudTheme.elevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isActive ? 0.18 : 0.10), lineWidth: 1)
            )
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
