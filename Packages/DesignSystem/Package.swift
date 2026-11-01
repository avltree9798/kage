// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "DesignSystem", targets: ["DesignSystem"])],
    dependencies: [
    ],
    targets: [
        .target(
            name: "DesignSystem",
            dependencies: [
            ]
        ),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ]
)
