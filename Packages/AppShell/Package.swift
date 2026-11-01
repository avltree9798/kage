// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppShell",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "AppShell", targets: ["AppShell"])],
    dependencies: [
        .package(path: "../KageModels"),
        .package(path: "../Persistence"),
        .package(path: "../BrowserCore"),
        .package(path: "../PrivacyKit"),
        .package(path: "../ContextAI"),
        .package(path: "../SecurityKit"),
        .package(path: "../PlatformAdapters"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "AppShell",
            dependencies: [
                .product(name: "KageModels", package: "KageModels"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "BrowserCore", package: "BrowserCore"),
                .product(name: "PrivacyKit", package: "PrivacyKit"),
                .product(name: "ContextAI", package: "ContextAI"),
                .product(name: "SecurityKit", package: "SecurityKit"),
                .product(name: "PlatformAdapters", package: "PlatformAdapters"),
                .product(name: "DesignSystem", package: "DesignSystem"),
            ]
        ),
        .testTarget(
            name: "AppShellTests",
            dependencies: ["AppShell", .product(name: "PrivacyKit", package: "PrivacyKit"), .product(name: "KageModels", package: "KageModels")]
        ),
    ]
)
