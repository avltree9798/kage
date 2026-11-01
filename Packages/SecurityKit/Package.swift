// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecurityKit",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "SecurityKit", targets: ["SecurityKit"])],
    dependencies: [
        .package(path: "../KageModels"),
    ],
    targets: [
        .target(
            name: "SecurityKit",
            dependencies: [
                .product(name: "KageModels", package: "KageModels"),
            ]
        ),
        .testTarget(name: "SecurityKitTests", dependencies: ["SecurityKit"]),
    ]
)
