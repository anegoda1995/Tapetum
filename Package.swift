// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tapetum",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "Tapetum",
            path: "Sources/Tapetum",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        )
    ]
)
