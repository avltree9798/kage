# Acceptance test coverage

| ID | Automated test(s) | Still needs on a device |
| --- | --- | --- |
| AT01 Browse without Cloudflare | App builds and runs with no credentials; `ContextPanel` shows the optional setup | Manual browsing pass |
| AT02 100 logical tabs | `TabResidencyTests.hundredTabsKeepOnlyCapResident`; UI test `TabMemoryTests` opens 100 real tabs and records peak memory (macOS in CI) | Same test on an iOS 27.2 device |
| AT03 History expiry | `SQLiteHistoryTests.expiredEntriesAreRemovedProtectedKept`, `RetentionActorTests` | |
| AT04 Protected login survives cleanup | `CleanupServiceTests`, `CleanupPlannerTests`; `WebKitCookieIntegrationTests` runs real `WKWebsiteDataStore` cookies through routine cleanup, Forget Now and Forget Everything | K-19: sign in to 3 real sites, protect one, clean, confirm only it stays signed in |
| AT05 Clear all | `forgetEverythingNeedsConfirmation`, `everythingIgnoresProtection` | |
| AT06 Private browsing | Nonpersistent store per session (`ProfileDataStores`), `privateProfileNeverAutoSubmitsAI` | Cookie isolation check on device |
| AT07 AI summary | `summarySendsRedactedPageThroughClient` | Live Cloudflare account |
| AT08 Token revoked | `failuresBecomeNotices(.invalidToken)`, `revokedTokenMapsToInvalidToken` | |
| AT09 Prompt injection | `promptInjectionYieldsOnlyAllowlistedProposals`, `pageCannotCloseUntrustedBlock` | |
| AT10 Lock conceals | `SessionLockTests` | App-switcher snapshot check |
| AT11 Duo geometry | `LayoutResolverTests` incl. `DuoSignals` mapping of `onHingeChange` and `reservedRegions` (iOS 27.1+ APIs) | iPhone Duo simulator with iOS 27.2 runtime, then hardware |
| AT12 Throw to Context | `BrowserTabStore.open(background:)` keeps the active tab | UI test |
| AT13 Cloudflare offline | `failuresBecomeNotices(.offline)` | |
| AT14 WebKit crash | `TabController.webViewWebContentProcessDidTerminate` sets `crashed`; `CrashRecoveryView` | Kill content process on device |
| AT15 iCloud off | `bookmarksAndReadingList` (local only) | |
| AT16 WARP unknown | `unknownNeverClaimsProtection`, `resolveRules`, `monitorVerifiesWithCloudflareWhenTunnelConnects`, `tunnelUpButNotWARPIsNotProtected`; `WireGuardConfigTests` | Install the tunnel with a real WARP config on a signed build |
| AT17 Accessibility | UI test `AccessibilityAuditTests` runs `performAccessibilityAudit` on browsing, Settings and Privacy, and a keyboard-only path (Cmd-L, Return, Cmd-T, Cmd-W) on macOS in CI | VoiceOver pass on an iOS 27.2 device |

## Hardware status (2026-11-01)

The user's Mac has Xcode 27.0 (needs 27.2), and the iPhone 14 Pro Max is on iOS 26.4.2 (needs 27.2, and isn't a Duo).
CI's `xcode-27` image has the iOS 27.2 SDK and an iPhone Duo simulator device type, but only 27.0/27.1 simulator
runtimes, so iOS UI tests run once a 27.2 runtime or device is available. Run them with
`xcodebuild test -scheme KageiOS -destination 'platform=iOS Simulator,name=iPhone Duo'`.
