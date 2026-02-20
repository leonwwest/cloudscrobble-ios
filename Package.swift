// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudScrobble",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CloudScrobbleCore",
            targets: ["CloudScrobbleCore"]
        ),
        .executable(
            name: "CloudScrobbleApp",
            targets: ["CloudScrobbleApp"]
        )
    ],
    targets: [
        .target(
            name: "CloudScrobbleCore",
            path: "Sources/CloudScrobbleCore"
        ),
        .executableTarget(
            name: "CloudScrobbleApp",
            dependencies: ["CloudScrobbleCore"],
            path: "Sources/CloudScrobbleApp"
        ),
        .testTarget(
            name: "CloudScrobbleCoreTests",
            dependencies: ["CloudScrobbleCore"],
            path: "Tests/CloudScrobbleCoreTests"
        )
    ]
)
