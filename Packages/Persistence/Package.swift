// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "Persistence", targets: ["Persistence"])],
    dependencies: [
        .package(path: "../KageModels"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [
                .product(name: "KageModels", package: "KageModels"),
            ]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", .product(name: "KageModels", package: "KageModels")]
        ),
    ]
)
