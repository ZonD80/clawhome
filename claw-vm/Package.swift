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
            name: "Cxz",
            path: "Sources/Cxz",
            exclude: ["COPYING"],
            sources: [
                "cxz.c", "xz_crc32.c", "xz_crc64.c", "xz_dec_stream.c", "xz_dec_lzma2.c",
                "xz_dec_bcj.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-w",
                    "-DXZ_USE_CRC64",
                    "-DXZ_DEC_ANY_CHECK",
                    "-DXZ_DEC_CONCATENATED",
                    "-DXZ_DEC_ARM64",
                    "-DXZ_DEC_X86",
                ]),
            ]
        ),
        .target(
            name: "ClawVMCore",
            dependencies: ["Cxz"],
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
