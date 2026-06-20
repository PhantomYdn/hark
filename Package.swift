// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hark",
    platforms: [
        .macOS("14.4")  // Core Audio process-tap API (PRD §7 Compatibility)
    ],
    products: [
        .executable(name: "hark", targets: ["CLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // Optional CoreML transcription engine (PRD §6.6 `whisperkit`); always
        // linked for now (PLAN Phase 6.3). Apple-Silicon-first.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0"),
        // CoreML Parakeet ASR engine (PRD §6.6 `parakeet`); always linked
        // (PLAN Phase 6.4). Apple-Silicon-first.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // Embedded HTTP/1.1 server for the remote-control agent (PRD §6.10,
        // PLAN Phase 10.3). Pure-Swift, minimal deps; statically linked so
        // there is nothing for users to install. MIT — see NOTICES.
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.20.0"),
    ],
    targets: [
        // Audio device & process enumeration (CoreAudio HAL).
        .target(name: "DeviceManager"),
        // Capture sessions: microphone now, Core Audio process taps in Phase 2.
        .target(name: "TapEngine", dependencies: ["DeviceManager", "Encoders"]),
        // Vendored libmp3lame (encode-only) for MP3 output (PRD §6.1). Source
        // under Sources/CLame; LGPL — see NOTICES.
        .target(
            name: "CLame",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
                // LAME's own sources have many such warnings; silence the noise.
                .unsafeFlags(["-w"]),
            ]),
        // Audio file writers/encoders: WAV/M4A/FLAC native; MP3 via CLame; Opus next.
        .target(name: "Encoders", dependencies: ["CLame"]),
        // The `hark` command-line interface.
        .executableTarget(
            name: "CLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
                "DeviceManager",
                "TapEngine",
                "Encoders",
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist (bundle ID + TCC usage descriptions) so
                // macOS can attribute audio-capture permissions to hark.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CLI/Info.plist",
                ])
            ]
        ),
        .testTarget(name: "DeviceManagerTests", dependencies: ["DeviceManager"]),
        .testTarget(name: "EncodersTests", dependencies: ["Encoders"]),
        .testTarget(name: "TapEngineTests", dependencies: ["TapEngine", "Encoders"]),
        .testTarget(
            name: "CLITests",
            dependencies: [
                "CLI",
                .product(name: "FlyingFox", package: "FlyingFox"),
            ]),
    ]
)
