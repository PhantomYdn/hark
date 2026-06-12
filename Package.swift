// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aural",
    platforms: [
        .macOS("14.4")  // Core Audio process-tap API (PRD §7 Compatibility)
    ],
    products: [
        .executable(name: "aural", targets: ["CLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // Audio device & process enumeration (CoreAudio HAL).
        .target(name: "DeviceManager"),
        // Capture sessions: microphone now, Core Audio process taps in Phase 2.
        .target(name: "TapEngine", dependencies: ["DeviceManager", "Encoders"]),
        // Audio file writers/encoders: WAV now, M4A/FLAC/MP3/Opus in Phase 3.
        .target(name: "Encoders"),
        // The `aural` command-line interface.
        .executableTarget(
            name: "CLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "DeviceManager",
                "TapEngine",
                "Encoders",
            ]
        ),
        .testTarget(name: "DeviceManagerTests", dependencies: ["DeviceManager"]),
        .testTarget(name: "EncodersTests", dependencies: ["Encoders"]),
        .testTarget(name: "CLITests", dependencies: ["CLI"]),
    ]
)
