// swift-tools-version:5.9
// Vendored from https://github.com/WireGuard/wireguard-apple at 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1 (MIT, see COPYING).
// Kage changes: platform floors raised to Kage's (the upstream .v12/.v15 floors are rejected by Xcode 27),
// and the Go bridge Makefile also targets the iOS simulator. See README.md.
import PackageDescription

let package = Package(
    name: "WireGuardKit",
    platforms: [.macOS("27.0"), .iOS("27.2")],
    products: [.library(name: "WireGuardKit", targets: ["WireGuardKit"])],
    targets: [
        .target(name: "WireGuardKit", dependencies: ["WireGuardKitGo", "WireGuardKitC"]),
        .target(name: "WireGuardKitC", publicHeadersPath: "."),
        .target(
            name: "WireGuardKitGo",
            exclude: ["goruntime-boottime-over-monotonic.diff", "go.mod", "go.sum", "api-apple.go", "Makefile"],
            publicHeadersPath: ".",
            linkerSettings: [.linkedLibrary("wg-go")]
        ),
    ]
)
