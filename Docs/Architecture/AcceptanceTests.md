# Acceptance test coverage

| ID | Automated test(s) | Still needs on a device |
| --- | --- | --- |
| AT01 Browse without Cloudflare | App builds and runs with no credentials; `ContextPanel` shows the optional setup | Manual browsing pass |
| AT02 100 logical tabs | `TabResidencyTests.hundredTabsKeepOnlyCapResident` | Memory profile with 100 real tabs |
| AT03 History expiry | `SQLiteHistoryTests.expiredEntriesAreRemovedProtectedKept`, `RetentionActorTests` | |
| AT04 Protected login survives cleanup | `CleanupServiceTests.protectedCookiesSurviveAndFailuresReported`, `CleanupPlannerTests` | K-19: real login sites |
| AT05 Clear all | `forgetEverythingNeedsConfirmation`, `everythingIgnoresProtection` | |
| AT06 Private browsing | Nonpersistent store per session (`ProfileDataStores`), `privateProfileNeverAutoSubmitsAI` | Cookie isolation check on device |
| AT07 AI summary | `summarySendsRedactedPageThroughClient` | Live Cloudflare account |
| AT08 Token revoked | `failuresBecomeNotices(.invalidToken)`, `revokedTokenMapsToInvalidToken` | |
| AT09 Prompt injection | `promptInjectionYieldsOnlyAllowlistedProposals`, `pageCannotCloseUntrustedBlock` | |
| AT10 Lock conceals | `SessionLockTests` | App-switcher snapshot check |
| AT11 Duo geometry | `LayoutResolverTests` | iPhone Duo hardware |
| AT12 Throw to Context | `BrowserTabStore.open(background:)` keeps the active tab | UI test |
| AT13 Cloudflare offline | `failuresBecomeNotices(.offline)` | |
| AT14 WebKit crash | `TabController.webViewWebContentProcessDidTerminate` sets `crashed`; `CrashRecoveryView` | Kill content process on device |
| AT15 iCloud off | `bookmarksAndReadingList` (local only) | |
| AT16 WARP unknown | `unknownNeverClaimsProtection` | |
| AT17 Accessibility | Labels on all chrome controls | VoiceOver and keyboard audit |
