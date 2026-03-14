// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "extradisplay",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "extradisplay",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/extradisplay",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "extradisplayTests",
            dependencies: ["extradisplay"],
            path: "Tests/extradisplayTests"
        ),
    ]
)
