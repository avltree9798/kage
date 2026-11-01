# Running Kage with a free Apple account

`Kage.xcodeproj` is the release build. It needs a paid Apple Developer team, because a free Personal Team
can't sign Network Extensions, iCloud, shared Keychain groups or the default-browser entitlement.
`project-local.yml` builds the same app without those, so a Personal Team can sign and run it.

## Mac

1. `brew install xcodegen` (once).
2. `cd ~/dev/kage && git pull`
3. `xcodegen generate --spec project-local.yml && open KageLocal.xcodeproj`
4. Select the **KageMacLocal** target, open **Signing & Capabilities**, and choose your Personal Team.
5. Choose the **KageMacLocal** scheme and **My Mac**, then press Run (⌘R).

The bundle ID is `dev.kage.local.<your Mac user name>.mac`, so it won't clash with anyone else's.
To keep the Team after regenerating, create `Config/Team.xcconfig` with `DEVELOPMENT_TEAM = <team ID>`.
The team ID is shown in Xcode › Settings › Accounts. The file isn't committed.

## iPhone

Needs Xcode 27.2 on the Mac and iOS 27.2 on the phone (Kage's minimum).

1. Turn on Developer Mode on the phone: Settings › Privacy & Security › Developer Mode.
2. Connect the phone, choose the **KageiOSLocal** scheme and the phone as the destination, set the Team
   on the **KageiOSLocal** target, and press Run.
3. The first time, trust your certificate on the phone: Settings › General › VPN & Device Management.

Apps signed by a free team stop opening after 7 days; run again from Xcode to renew.

## What's off in the local build

| Feature | Local build |
| --- | --- |
| WireGuard tunnel (Network Protection) | Not included. The tunnel controls don't appear. |
| Encrypted DNS | Off. Network Protection says it needs a paid account. |
| iCloud bookmark sync | Off. |
| Set as default browser (iOS) | Not available. Apple grants this entitlement only to paid teams. |

The rest is the same code as the release build: tabs, profiles, the Vault with its Secure Enclave key, the
lock purge, tracker blocking, Context AI, screen-capture hiding and the Duo layout.

## Tests

Package tests need no signing: `for p in Packages/*/; do swift test --package-path "$p"; done`.
