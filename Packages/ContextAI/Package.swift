// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextAI",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "ContextAI", targets: ["ContextAI"])],
    dependencies: [
        .package(path: "../KageModels"),
        .package(path: "../Persistence"),
        .package(path: "../SecurityKit"),
    ],
    targets: [
        .target(
            name: "ContextAI",
            dependencies: [
                .product(name: "KageModels", package: "KageModels"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "SecurityKit", package: "SecurityKit"),
            ]
        ),
        .testTarget(name: "ContextAITests", dependencies: ["ContextAI"]),
    ]
)
