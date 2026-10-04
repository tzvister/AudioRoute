// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "AudioRoute",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "audioroute", targets: ["audioroute"]), .executable(name: "audiorouted", targets: ["audiorouted"])],
    targets: [
        .target(name: "AudioRouteCore"),
        .target(name: "VirtualAudioTransport", publicHeadersPath: "include"),
        .target(name: "CAudioRT", publicHeadersPath: "include"),
        .target(name: "AudioRouteEngine", dependencies: ["AudioRouteCore", "CAudioRT", "VirtualAudioTransport"], linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"), .linkedFramework("AVFoundation"), .linkedFramework("AppKit")]),
        .target(name: "AudioRouteControl", dependencies: ["AudioRouteCore", "AudioRouteEngine", "VirtualAudioTransport"]),
        .executableTarget(name: "audioroute", dependencies: ["AudioRouteControl"]),
        .executableTarget(name: "audiorouted", dependencies: ["AudioRouteControl"]),
        .testTarget(name: "AudioRouteCoreTests", dependencies: ["AudioRouteCore"]),
        .testTarget(name: "AudioRouteEngineTests", dependencies: ["AudioRouteEngine", "CAudioRT", "VirtualAudioTransport"]),
        .testTarget(name: "AudioRouteControlTests", dependencies: ["AudioRouteControl"])
    ],
    swiftLanguageModes: [.v5]
)
