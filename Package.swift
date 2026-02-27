// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicalWallpaper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MusicalWallpaper", targets: ["MusicalWallpaper"])
    ],
    targets: [
        .executableTarget(
            name: "MusicalWallpaper",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("SceneKit")
            ]
        )
    ]
)
