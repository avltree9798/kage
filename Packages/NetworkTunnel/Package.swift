// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetworkTunnel",
    platforms: [.iOS("27.2"), .macOS("27.0")],
    products: [.library(name: "NetworkTunnel", targets: ["NetworkTunnel"])],
    targets: [
        .target(name: "NetworkTunnel"),
        .testTarget(name: "NetworkTunnelTests", dependencies: ["NetworkTunnel"]),
    ]
)
