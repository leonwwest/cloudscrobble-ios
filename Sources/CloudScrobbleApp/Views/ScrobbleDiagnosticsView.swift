import CloudScrobbleCore
import SwiftUI

struct ScrobbleDiagnosticsView: View {
    @ObservedObject var controller: PlayerScrobbleController
    @State private var showClearHistoryConfirmation = false

    var onRefresh: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summarySection
                    historySection
                    playbackProblemSection
                }
                .padding(16)
            }
            .background(CloudBackdrop())
            .navigationTitle("Diagnostics")
            .cloudInlineNavigationTitle()
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") {
                        onRefresh?()
                    }
                }
#else
                ToolbarItem {
                    Button("Refresh") {
                        onRefresh?()
                    }
                }
#endif
            }
        }
        .presentationDetents([.medium, .large])
        .confirmationDialog(
            "Clear scrobble history?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                controller.clearScrobbleHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes local diagnostics. It does not delete scrobbles from Last.fm.")
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Last.fm Status", systemImage: "dot.radiowaves.left.and.right")
                .font(.system(.headline, design: .rounded).weight(.black))
                .foregroundStyle(CloudTheme.ink)
                .accessibilityIdentifier("diagnostics-lastfm-status-title")

            DiagnosticsInfoRow(title: "Current status", value: controller.debugStatus.isEmpty ? "Ready" : controller.debugStatus)
            DiagnosticsInfoRow(title: "Pending scrobbles", value: "\(controller.pendingScrobbleCount)")

            if let lastScrobbleSucceededAt = controller.lastScrobbleSucceededAt {
                DiagnosticsInfoRow(title: "Last scrobble", value: lastScrobbleSucceededAt.formatted(date: .abbreviated, time: .shortened))
            }

            if let lastScrobbleError = controller.lastScrobbleError {
                DiagnosticsInfoRow(title: "Last.fm error", value: lastScrobbleError, isWarning: true)
            }

            if controller.skippedUnplayableCount > 0 {
                DiagnosticsInfoRow(
                    title: "Skipped streams",
                    value: controller.skippedUnplayableCount == 1
                        ? String(localized: "1 unplayable track skipped")
                        : String(localized: "\(controller.skippedUnplayableCount) unplayable tracks skipped"),
                    isWarning: true
                )
            }
        }
        .cloudCard()
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Scrobble History", systemImage: "list.bullet.clipboard")
                    .font(.system(.headline, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)
                    .accessibilityIdentifier("diagnostics-scrobble-history-title")

                Spacer()

                if !controller.scrobbleHistory.isEmpty {
                    Button {
                        showClearHistoryConfirmation = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconCircleButtonStyle())
                    .accessibilityLabel("Clear scrobble history")
                }
            }

            if controller.scrobbleHistory.isEmpty {
                Text("No Last.fm events on this install yet.")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(CloudTheme.muted)
                    .padding(.vertical, 4)
            } else {
                ForEach(controller.scrobbleHistory.prefix(40)) { entry in
                    DiagnosticsHistoryRow(entry: entry)
                }
            }
        }
        .cloudCard()
    }

    @ViewBuilder
    private var playbackProblemSection: some View {
        if controller.skippedUnplayableCount > 0 || controller.lastScrobbleError != nil || controller.pendingScrobbleCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label("What this means", systemImage: "info.circle.fill")
                    .font(.system(.headline, design: .rounded).weight(.black))
                    .foregroundStyle(CloudTheme.ink)

                if controller.pendingScrobbleCount > 0 {
                    Text("Queued scrobbles are kept locally and retried when Last.fm is reachable again.")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                }

                if controller.lastScrobbleError != nil {
                    Text("A Last.fm error usually means the session expired, Last.fm is temporarily unavailable, or the request hit a rate limit.")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                }

                if controller.skippedUnplayableCount > 0 {
                    Text("Skipped streams are SoundCloud items that did not provide a playable stream URL or stalled for too long.")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(CloudTheme.muted)
                }
            }
            .cloudCard()
        }
    }
}

private struct DiagnosticsInfoRow: View {
    let title: String
    let value: String
    var isWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .foregroundStyle(CloudTheme.muted)
                .textCase(.uppercase)

            Text(LocalizedStringKey(value))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(isWarning ? CloudTheme.warning : CloudTheme.ink)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnosticsHistoryRow: View {
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
            return String(localized: "Now Playing")
        case .scrobbled:
            return String(localized: "Sent")
        case .queued:
            return String(localized: "Queued")
        case .failed:
            return String(localized: "Failed")
        case .skipped:
            return String(localized: "Skipped")
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
