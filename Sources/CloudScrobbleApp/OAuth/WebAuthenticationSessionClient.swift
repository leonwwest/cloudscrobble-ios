import AuthenticationServices
import CloudScrobbleCore
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WebAuthenticationSessionClient: NSObject {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: CloudScrobbleError.oauthCallbackMissingCode)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            // Use the default browser session to avoid provider-specific login issues in strict ephemeral mode.
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.session = session
            guard session.start() else {
                continuation.resume(
                    throwing: CloudScrobbleError.invalidConfiguration(
                        "Could not start the iOS web authentication session."
                    )
                )
                return
            }
        }
    }
}

extension WebAuthenticationSessionClient: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if canImport(UIKit)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { !$0.isHidden }

        if let keyWindow = windows.first(where: \.isKeyWindow) {
            return keyWindow
        }

        if let largestWindow = windows.max(by: { ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height) }) {
            return largestWindow
        }

        return ASPresentationAnchor()
#elseif canImport(AppKit)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
#else
        return ASPresentationAnchor()
#endif
    }
}
