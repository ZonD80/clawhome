// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClawVM",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", .upToNextMajor(from: "1.5.0")),
    ],
    targets: [
        .target(
            name: "ClawVMCore",
            path: "Sources/ClawVMCore",
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Network"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(
            name: "ClawVMManager",
            dependencies: ["ClawVMCore", .product(name: "Swifter", package: "swifter")],
            path: "Sources/ClawVMManager",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Network"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(
            name: "ClawVMRunner",
            dependencies: ["ClawVMCore"],
            path: "Sources/ClawVMRunner",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("Virtualization"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Network"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
    ]
)
