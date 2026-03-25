// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "acuity",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "acuity",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/acuity",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "acuityTests",
            dependencies: ["acuity"],
            path: "Tests/acuityTests"
        ),
    ]
)
