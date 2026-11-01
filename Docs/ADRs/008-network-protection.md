# ADR-008 (rev. 2): Network Protection through Kage's own WireGuard tunnel

Status: accepted 2026-11-01 (the user chose "Built-in WireGuard tunnel").

## Decision

Kage ships a packet-tunnel Network Extension (`KageTunneliOS`, `KageTunnelMac`) that runs a WireGuard config the
user imports, using WireGuardKit (wireguard-apple, MIT) and wireguard-go. Kage does not call Cloudflare's private
WARP registration API: it's undocumented and likely against Cloudflare's terms. A WARP config, or one from any other
WireGuard provider, is imported as a `.conf` file or pasted text.

## Verification (AT16)

"Protected by WARP" (`verifiedConnected`) needs both of these:
1. The system reports Kage's tunnel as `NEVPNStatus.connected`.
2. Cloudflare's public `cdn-cgi/trace` fetched over that connection says `warp=on` or `warp=plus`.

Tunnel up with any other trace → "Tunnel on, not WARP". No trace → "Status unknown". The rule is
`NetworkProtectionState.resolve` and is unit tested. The Phase A path (the user runs Cloudflare's own app) stays,
and is never shown as verified.

## Secrets

The wg-quick text holds the private key. It's stored as a Keychain item in the shared group
`<TeamID>.dev.kage.shared` (`AfterFirstUnlockThisDeviceOnly`, not synced). The VPN profile carries only the item's
persistent reference. `WireGuardConfig.description` redacts keys, and the extension logs no keys, addresses or traffic.

## Consequences

- The tunnel is a system VPN: while it's on, it carries all device traffic, not only Kage's. The UI says so.
- Building the extension needs Go on the build Mac (CI installs it). WireGuardKit is pinned via `Package.resolved`.
- App Store review: a VPN app must be published by an organisation account and must declare the VPN use
  (App Store Review Guideline 5.4).
- macOS: the extension ships as an app extension, which works for Mac App Store distribution. Distributing outside
  the Mac App Store would need a system extension instead.
