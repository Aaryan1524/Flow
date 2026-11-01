// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Flow",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FlowKit", targets: ["FlowKit"]),
        .library(name: "ASR", targets: ["ASR"]),
        .library(name: "Cleanup", targets: ["Cleanup"]),
        .library(name: "Hotkey", targets: ["Hotkey"]),
        .library(name: "Audio", targets: ["Audio"]),
        .library(name: "Insertion", targets: ["Insertion"]),
        .library(name: "History", targets: ["History"]),
        .executable(name: "flow-eval", targets: ["flow-eval"]),
        .executable(name: "flow-record", targets: ["flow-record"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.18.0")),
    ],
    targets: [
        // Shared types and pure logic (no system dependencies, fully unit-testable)
        .target(name: "FlowKit", path: "Sources/FlowKit"),

        // Speech-to-text engines behind the Transcriber protocol
        .target(
            name: "ASR",
            dependencies: [
                "FlowKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/ASR"
        ),

        // Text cleanup behind the TextCleaner protocol: deterministic rules, Apple Foundation Models, Ollama
        .target(
            name: "Cleanup",
            dependencies: ["FlowKit"],
            path: "Sources/Cleanup"
        ),

        // Hold-to-talk key detection (Fn / Globe)
        .target(name: "Hotkey", path: "Sources/Hotkey"),

        // Microphone capture as 16 kHz mono, plus silence checks
        .target(name: "Audio", path: "Sources/Audio"),

        // Putting text at the cursor of the frontmost app
        .target(name: "Insertion", path: "Sources/Insertion"),

        // Local dictation log (JSON Lines)
        .target(name: "History", path: "Sources/History"),

        // Command-line harness: runs your clips through every engine, reports WER and latency
        .executableTarget(
            name: "flow-eval",
            dependencies: ["FlowKit", "ASR", "Cleanup"],
            path: "Tools/flow-eval"
        ),

        // Records your own voice reading evals/script.txt, to build the test set
        .executableTarget(name: "flow-record", dependencies: ["Audio"], path: "Tools/flow-record"),

        .testTarget(name: "FlowKitTests", dependencies: ["FlowKit"], path: "Tests/FlowKitTests"),
        .testTarget(name: "HotkeyTests", dependencies: ["Hotkey"], path: "Tests/HotkeyTests"),
        .testTarget(name: "AudioTests", dependencies: ["Audio"], path: "Tests/AudioTests"),
        .testTarget(name: "InsertionTests", dependencies: ["Insertion"], path: "Tests/InsertionTests"),
        .testTarget(name: "HistoryTests", dependencies: ["History"], path: "Tests/HistoryTests"),
        .testTarget(name: "CleanupTests", dependencies: ["FlowKit", "Cleanup"], path: "Tests/CleanupTests"),
    ]
)
