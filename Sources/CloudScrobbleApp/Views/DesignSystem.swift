import SwiftUI

enum CloudTheme {
    static let night = Color(red: 0.06, green: 0.11, blue: 0.20)
    static let dusk = Color(red: 0.10, green: 0.24, blue: 0.42)
    static let sky = Color(red: 0.19, green: 0.56, blue: 0.85)
    static let seafoam = Color(red: 0.33, green: 0.74, blue: 0.72)
    static let shell = Color(red: 0.95, green: 0.97, blue: 1.00)
    static let ink = Color(red: 0.07, green: 0.12, blue: 0.19)
    static let muted = Color(red: 0.34, green: 0.42, blue: 0.50)
    static let success = Color(red: 0.16, green: 0.67, blue: 0.47)
    static let warning = Color(red: 0.86, green: 0.32, blue: 0.30)
}

struct CloudBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [CloudTheme.night, CloudTheme.dusk],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(CloudTheme.sky.opacity(0.35))
                .frame(width: 360, height: 360)
                .blur(radius: 40)
                .offset(x: 180, y: -240)

            Circle()
                .fill(CloudTheme.seafoam.opacity(0.25))
                .frame(width: 280, height: 280)
                .blur(radius: 34)
                .offset(x: -140, y: 220)
        }
        .ignoresSafeArea()
    }
}

struct CloudCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(CloudTheme.shell.opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 8)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [CloudTheme.sky, CloudTheme.seafoam],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(CloudTheme.ink)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.7 : 0.9))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(CloudTheme.sky.opacity(0.35), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct StatusBadge: View {
    let title: String
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? CloudTheme.success : CloudTheme.warning)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.system(.caption, design: .rounded).weight(.bold))
            Text(isConnected ? "Connected" : "Offline")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(CloudTheme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.9))
        )
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(CloudTheme.sky)
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(CloudTheme.ink)
            Text(subtitle)
                .multilineTextAlignment(.center)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(CloudTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .cloudCard()
    }
}
