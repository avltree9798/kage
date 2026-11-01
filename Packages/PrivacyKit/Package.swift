// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrivacyKit",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "PrivacyKit", targets: ["PrivacyKit"])],
    dependencies: [
        .package(path: "../KageModels"),
        .package(path: "../Persistence"),
        .package(path: "../SecurityKit"),
    ],
    targets: [
        .target(
            name: "PrivacyKit",
            dependencies: [
                .product(name: "KageModels", package: "KageModels"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "SecurityKit", package: "SecurityKit"),
            ]
        ),
        .testTarget(
            name: "PrivacyKitTests",
            dependencies: ["PrivacyKit", .product(name: "KageModels", package: "KageModels"),
                           .product(name: "Persistence", package: "Persistence"), .product(name: "SecurityKit", package: "SecurityKit")]
        ),
    ]
)
