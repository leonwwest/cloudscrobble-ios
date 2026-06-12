import Foundation
import SwiftUI

@main
struct CloudScrobbleApplication: App {
    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1_024 * 1_024,
            diskCapacity: 256 * 1_024 * 1_024
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
