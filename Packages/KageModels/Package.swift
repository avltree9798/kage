// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KageModels",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "KageModels", targets: ["KageModels"])],
    dependencies: [
    ],
    targets: [
        .target(
            name: "KageModels",
            dependencies: [
            ]
        ),
        .testTarget(name: "KageModelsTests", dependencies: ["KageModels"]),
    ]
)
