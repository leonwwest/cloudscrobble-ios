import SwiftUI

enum CloudTheme {
    static let night = Color(red: 0.03, green: 0.07, blue: 0.13)
    static let dusk = Color(red: 0.11, green: 0.20, blue: 0.33)
    static let sky = Color(red: 0.12, green: 0.67, blue: 0.88)
    static let seafoam = Color(red: 0.33, green: 0.84, blue: 0.64)
    static let shell = Color(red: 0.96, green: 0.97, blue: 0.99)
    static let ink = Color(red: 0.08, green: 0.11, blue: 0.19)
    static let muted = Color(red: 0.35, green: 0.42, blue: 0.50)
    static let success = Color(red: 0.08, green: 0.68, blue: 0.47)
    static let warning = Color(red: 0.90, green: 0.33, blue: 0.23)

    static let violet = Color(red: 0.33, green: 0.34, blue: 0.79)
    static let amber = Color(red: 0.98, green: 0.71, blue: 0.22)
}

struct CloudBackdrop: View {
    var body: some View {
        ZStack {
            AngularGradient(
                colors: [CloudTheme.night, CloudTheme.violet, CloudTheme.dusk, CloudTheme.night],
                center: .topLeading
            )
            .overlay(
                LinearGradient(
                    colors: [Color.clear, CloudTheme.night.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Circle()
                .fill(CloudTheme.sky.opacity(0.35))
                .frame(width: 350, height: 350)
                .blur(radius: 56)
                .offset(x: 170, y: -260)

            Circle()
                .fill(CloudTheme.amber.opacity(0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 48)
                .offset(x: -140, y: -110)

            Circle()
                .fill(CloudTheme.seafoam.opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 44)
                .offset(x: -140, y: 250)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), Color.clear, Color.white.opacity(0.04)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .blendMode(.softLight)
                .rotationEffect(.degrees(-8))
                .scaleEffect(1.45)
        }
        .ignoresSafeArea()
    }
}

struct CloudCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [CloudTheme.shell.opacity(0.97), Color.white.opacity(0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.92), CloudTheme.sky.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
            )
            .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
            .shadow(color: CloudTheme.sky.opacity(0.08), radius: 10, x: 0, y: 2)
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
            .font(.system(.body, design: .serif).weight(.bold))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [CloudTheme.sky, CloudTheme.violet, CloudTheme.seafoam],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: CloudTheme.sky.opacity(0.38), radius: 12, x: 0, y: 7)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .serif).weight(.semibold))
            .foregroundStyle(CloudTheme.ink)
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.74 : 0.92))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [CloudTheme.sky.opacity(0.45), CloudTheme.seafoam.opacity(0.3)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1
                    )
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
                .frame(width: 9, height: 9)
            Text(title)
                .font(.system(.caption, design: .serif).weight(.bold))
            Text(isConnected ? "Connected" : "Offline")
                .font(.system(.caption, design: .serif))
                .foregroundStyle(CloudTheme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.95))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.75), lineWidth: 1)
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
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(CloudTheme.sky)
            Text(title)
                .font(.system(.headline, design: .serif).weight(.bold))
                .foregroundStyle(CloudTheme.ink)
            Text(subtitle)
                .multilineTextAlignment(.center)
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(CloudTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .cloudCard()
    }
}
