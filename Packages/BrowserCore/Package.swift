// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BrowserCore",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "BrowserCore", targets: ["BrowserCore"])],
    dependencies: [
        .package(path: "../KageModels"),
        .package(path: "../Persistence"),
        .package(path: "../PrivacyKit"),
        .package(path: "../SecurityKit"),
    ],
    targets: [
        .target(
            name: "BrowserCore",
            dependencies: [
                .product(name: "KageModels", package: "KageModels"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "PrivacyKit", package: "PrivacyKit"),
                .product(name: "SecurityKit", package: "SecurityKit"),
            ]
        ),
        .testTarget(
            name: "BrowserCoreTests",
            dependencies: ["BrowserCore", .product(name: "KageModels", package: "KageModels"),
                           .product(name: "Persistence", package: "Persistence"), .product(name: "PrivacyKit", package: "PrivacyKit")]
        ),
    ]
)
