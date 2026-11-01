// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlatformAdapters",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "PlatformAdapters", targets: ["PlatformAdapters"])],
    dependencies: [
        .package(path: "../KageModels"),
    ],
    targets: [
        .target(
            name: "PlatformAdapters",
            dependencies: [
                .product(name: "KageModels", package: "KageModels"),
            ]
        ),
        .testTarget(name: "PlatformAdaptersTests", dependencies: ["PlatformAdapters"]),
    ]
)
