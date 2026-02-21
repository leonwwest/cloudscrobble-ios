import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class SystemBrowserClient {
#if canImport(AuthenticationServices) && canImport(UIKit)
    private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }

    private let contextProvider = PresentationContextProvider()
    private var activeSession: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                self?.activeSession = nil

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: URLError(.cancelled))
                }
            }

            session.presentationContextProvider = contextProvider
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session

            guard session.start() else {
                activeSession = nil
                continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
                return
            }
        }
    }
#endif

    func open(url: URL) throws {
#if canImport(UIKit)
        UIApplication.shared.open(url)
#elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
#else
        throw URLError(.unsupportedURL)
#endif
    }
}
