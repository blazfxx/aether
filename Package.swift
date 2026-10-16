// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Aether",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Aether", targets: ["Aether"]),
    ],
    targets: [
        .target(
            name: "AetherCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Aether",
            dependencies: ["AetherCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command Line Tools ship no XCTest, so the engine's checks run as a plain executable: `swift run AetherCheck`.
        .executableTarget(
            name: "AetherCheck",
            dependencies: ["AetherCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
