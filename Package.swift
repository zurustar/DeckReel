// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeckReel",
    platforms: [.macOS(.v14)],
    targets: [
        // PPTX parsing, VOICEVOX, cache, media (AVFoundation) and the pipeline.
        .target(name: "DeckReelCore"),
        // SwiftUI app. Built into dist/DeckReel.app by scripts/build-app.sh.
        .executableTarget(name: "DeckReelApp", dependencies: ["DeckReelCore"]),
        // Command-line interface. Copied to dist/deckreel.
        .executableTarget(name: "DeckReelCLI", dependencies: ["DeckReelCore"]),
        .testTarget(name: "DeckReelCoreTests", dependencies: ["DeckReelCore"]),
    ]
)
