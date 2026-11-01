# Vendored WireGuardKit

Source: https://github.com/WireGuard/wireguard-apple, commit 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1 (2023-02-15).
Licence: MIT (COPYING). Only `Sources/WireGuardKit`, `Sources/WireGuardKitC` and `Sources/WireGuardKitGo` are included.

Kage's changes:
- `Package.swift`: platform floors set to iOS 27.2 / macOS 27.0, because Xcode 27's PackageDescription rejects the
  upstream `.v12` / `.v15` values, so the upstream package doesn't resolve.
- `Sources/WireGuardKitGo/Makefile`: `GOOS_iphonesimulator := ios`, so simulator builds work, and the Go runtime
  boottime patch is allowed to fail on Go versions it no longer applies to. Without that patch, Go timers use the
  monotonic clock, which pauses while the device sleeps, so the first handshake after a wake can be late.

To update: replace the three Sources folders from upstream and re-apply the two changes above.
