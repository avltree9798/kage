# Release checklist: steps only the account holder can do

Everything in code is in place: entitlements, Info.plist keys, the tunnel extension, the bundled ruleset and the
model registry. These steps need the Apple Developer or Cloudflare account and can't be done from the repository.
Team ID seen on the build Mac: W6RB25ZNB7 (Apple Development certificate only).

## 1. App IDs and capabilities (developer.apple.com > Certificates, IDs & Profiles > Identifiers)

| Identifier | Capabilities to tick |
|---|---|
| `dev.kage.ios` | iCloud (CloudKit), Network Extensions, Default Browser (after approval, see 3), Keychain Sharing is automatic via `keychain-access-groups` |
| `dev.kage.ios.tunnel` | Network Extensions |
| `dev.kage.mac` | iCloud (CloudKit), Network Extensions, App Sandbox is automatic |
| `dev.kage.mac.tunnel` | Network Extensions |

Then in Xcode, set the Development Team on all four targets (or `DEVELOPMENT_TEAM: W6RB25ZNB7` in `project.yml`
settings) and let automatic signing create the profiles.

## 2. iCloud container (bookmark sync, spec 10)

1. Identifiers > the "+" button > iCloud Containers > identifier `iCloud.dev.kage`.
2. Open `dev.kage.ios` and `dev.kage.mac` > iCloud > Configure > tick `iCloud.dev.kage`.
3. CloudKit Console (icloud.developer.apple.com) > `iCloud.dev.kage` > Development: the `KageBookmark` record type is
   created on first sync. Before release, Deploy Schema Changes to Production.
4. A different container name: change `KAGE_CLOUDKIT_CONTAINER` in `project.yml` and the two app entitlements. An empty
   value turns sync off.

## 3. Default-browser entitlement (`com.apple.developer.web-browser`)

1. Email `default-browser-requests@apple.com` from the Account Holder's address. Include the app name (Kage), bundle
   ID `dev.kage.ios`, and confirm the app meets Apple's requirements: it opens any http/https URL, shows a URL field
   and search, doesn't hard-code a home page that redirects to another app, and uses WebKit. Kage does all of these.
2. When Apple grants it, the capability "Default Browser" appears on `dev.kage.ios`. Tick it and regenerate profiles.
   The entitlement is already in `Apps/KageiOS/Kage.entitlements`; until it's granted, signed device builds fail on
   that key, so remove it locally for development builds before approval.
3. macOS needs no entitlement: Kage registers http/https URL types and the user picks it in System Settings.

## 4. VPN / Network Extension (ADR-008 rev. 2)

- App Store Review 5.4: VPN apps must be submitted by an organisation account (not an individual), must use
  NEVPNManager / Network Extension (Kage does), and the listing must say what's collected (nothing).
- No Apple request form is needed for `packet-tunnel-provider` any more; ticking Network Extensions is enough.
- The apps also use `dns-settings` (Encrypted DNS, threat model T-13). It comes with the same Network Extensions capability.
- Build Macs need Go (`brew install go`) for the WireGuard bridge.

## 5. Tracker ruleset (K-21)

Bundled: EasyPrivacy (CC BY-SA 3.0), 47,084 hosts, version 202611012111. Before each release, copy the list printed by
CI's `tracker-rules` job (or run `scripts/build-tracker-rules.py`) into
`Packages/SecurityKit/Sources/SecurityKit/Resources/easyprivacy-hosts.txt`. Attribution is in Settings > About.

## 6. Workers AI models

Checked against Cloudflare's catalogue and deprecation notices on 2026-11-01. `@cf/meta/llama-3.1-8b-instruct` was
retired on 2026-05-30 and has been replaced. To check against a real account, run
`CF_ACCOUNT_ID=... CF_API_TOKEN=... scripts/check-models.sh` locally, or add them as repository secrets to run it in CI.
Users see the same check under Settings > Cloudflare Workers AI > Test Connection.
