import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class SystemBrowserClient {
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

