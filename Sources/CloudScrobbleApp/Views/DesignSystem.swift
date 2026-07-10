import SwiftUI

enum CloudTheme {
    static let night = Color(red: 0.02, green: 0.02, blue: 0.03)
    static let dusk = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let sky = Color(red: 0.92, green: 0.28, blue: 0.03)
    static let seafoam = Color(red: 0.12, green: 0.78, blue: 0.68)
    static let shell = Color.primary.opacity(0.09)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let success = Color(red: 0.12, green: 0.78, blue: 0.50)
    static let warning = Color(red: 1.00, green: 0.64, blue: 0.25)

    static let violet = Color(red: 0.33, green: 0.52, blue: 0.96)
    static let amber = Color(red: 1.00, green: 0.76, blue: 0.25)
    static let line = Color.primary.opacity(0.11)
    static let elevated = Color.primary.opacity(0.075)
    static let elevatedStrong = Color.primary.opacity(0.13)
}

struct CloudBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: baseColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    CloudTheme.sky.opacity(colorScheme == .dark ? 0.22 : 0.12),
                    Color.clear,
                    CloudTheme.seafoam.opacity(colorScheme == .dark ? 0.10 : 0.07)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 18) {
                ForEach(0..<9, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white.opacity(index.isMultiple(of: 3) ? 0.045 : 0.024))
                        .frame(height: 1)
                }
            }
            .rotationEffect(.degrees(-8))
            .scaleEffect(1.4)
            .blendMode(.screen)
        }
        .ignoresSafeArea()
    }

    private var baseColors: [Color] {
        if colorScheme == .dark {
            return [
                CloudTheme.night,
                Color(red: 0.06, green: 0.04, blue: 0.035),
                CloudTheme.dusk,
                CloudTheme.night
            ]
        }

        return [
            Color(red: 0.98, green: 0.97, blue: 0.95),
            Color(red: 1.00, green: 0.98, blue: 0.95),
            Color(red: 0.94, green: 0.96, blue: 0.98),
            Color(red: 0.98, green: 0.98, blue: 0.97)
        ]
    }
}

struct CloudCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CloudTheme.elevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(CloudTheme.line, lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10),
                radius: 18,
                x: 0,
                y: 12
            )
    }
}

extension View {
    func cloudCard() -> some View {
        modifier(CloudCardModifier())
    }

    @ViewBuilder
    func cloudInlineNavigationTitle() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func cloudCredentialField() -> some View {
#if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
#else
        self
#endif
    }
}

struct PrimaryPillButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.84)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(CloudTheme.sky.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.20), lineWidth: 1)
            )
            .shadow(color: CloudTheme.sky.opacity(configuration.isPressed ? 0.10 : 0.30), radius: 14, x: 0, y: 8)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct SecondaryPillButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(CloudTheme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.84)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? CloudTheme.elevatedStrong : CloudTheme.elevated)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(CloudTheme.line, lineWidth: 1)
            )
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct IconCircleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isPrimary ? 19 : 16, weight: .bold, design: .rounded))
            .foregroundStyle(isPrimary ? .white : CloudTheme.ink)
            .frame(width: isPrimary ? 58 : 44, height: isPrimary ? 58 : 44)
            .background(
                Circle()
                    .fill(isPrimary ? CloudTheme.sky : CloudTheme.elevated)
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(isPrimary ? 0.20 : 0.12), lineWidth: 1)
            )
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct StatusBadge: View {
    let title: String
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isConnected ? CloudTheme.success : CloudTheme.warning)
                .frame(width: 7, height: 7)
            Text(LocalizedStringKey(title))
                .font(.system(.caption2, design: .rounded).weight(.bold))
                .lineLimit(1)
            Text(LocalizedStringKey(isConnected ? "On" : "Off"))
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.muted)
                .lineLimit(1)
        }
        .foregroundStyle(CloudTheme.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(CloudTheme.elevated)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(CloudTheme.line, lineWidth: 1)
        )
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(CloudTheme.sky)
                .frame(width: 50, height: 50)
                .background(Circle().fill(CloudTheme.sky.opacity(0.14)))
            Text(LocalizedStringKey(title))
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(CloudTheme.ink)
            Text(LocalizedStringKey(subtitle))
                .multilineTextAlignment(.center)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(CloudTheme.muted)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .cloudCard()
    }
}

struct LoadingResultSkeleton: View {
    var showsArtwork = true

    var body: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CloudTheme.elevatedStrong)
                    .frame(width: 56, height: 56)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(CloudTheme.line, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(CloudTheme.elevatedStrong)
                    .frame(height: 14)
                    .frame(maxWidth: 210)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(CloudTheme.elevatedStrong.opacity(0.75))
                    .frame(height: 10)
                    .frame(maxWidth: 135)
            }

            Spacer()

            Circle()
                .fill(CloudTheme.elevatedStrong)
                .frame(width: 36, height: 36)
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
        .redacted(reason: .placeholder)
    }
}

struct LoadingResultSkeletonList: View {
    var count = 5
    var showsArtwork = true

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(0..<count, id: \.self) { _ in
                LoadingResultSkeleton(showsArtwork: showsArtwork)
            }
        }
    }
}
