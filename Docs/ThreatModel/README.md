# Threat model (K-03)

Derived from spec section 15. Each threat lists the control in code and the test that covers it.

| Threat | Control | Where | Test |
| --- | --- | --- | --- |
| Malicious page runs script in Kage's context | Native scripts run only in the `dev.kage.native` content world; no script message handlers are exposed to the page world | `BrowserCore/WebViewFactory.swift` | Manual: page-world probe for `webkit.messageHandlers` |
| Deceptive chrome / phishing | Chrome is native SwiftUI on its own surface; site identity shows the real host; JS dialogs are titled with the requesting host | `AppShell/Views/CanvasView.swift`, `RootView.swift` (PromptHost) | UI review |
| Top-level `data:`/`javascript:`/`file:` navigation | Blocked by `NavigationPolicy` | `BrowserCore/NavigationPolicy.swift` | `NavigationPolicyTests` |
| Silent hand-off to other apps | External schemes need a user gesture and a confirmation | `NavigationPolicy`, `TabController` | `NavigationPolicyTests.externalAppsNeedAGesture` |
| Popup spam | Popups only from user-activated links; others counted and blocked | `TabController.createWebViewWith` | Manual |
| Malicious downloads | Filenames sanitised (paths, control and bidi characters); risky types flagged | `BrowserCore/Downloads.swift` | `FilenameTests` |
| Credential theft from Kage | Cloudflare token in Keychain, this device only, never synced; redacted from descriptions | `SecurityKit/Keychain.swift` | `CredentialTests` |
| Prompt injection | Page text wrapped as untrusted with a per-request nonce; delimiter spoofing neutralised; output parsed against an allowlist; every action needs confirmation | `ContextAI/PromptSafety.swift`, `ContextPanel` | AT09: `promptInjectionYieldsOnlyAllowlistedProposals`, `pageCannotCloseUntrustedBlock` |
| Sensitive data sent to AI | Automatic AI off by default; sensitive and private pages need explicit consent; local redaction of emails, card numbers, IBANs, SSNs, JWTs and inline secrets; transmission indicator | `PrivacyKit/SensitiveSites.swift`, `ContextAI` | `sensitiveSiteRequiresConsent`, `redactsCredentials` |
| AI requests carry browser cookies | Ephemeral `URLSession`, no cookie storage, `httpShouldHandleCookies = false` | `ContextAI/CloudflareClient.swift` | `requestCarriesNoCookiesAndUsesBearerToken` |
| Unintended retention | Exact Kage expiry; idempotent cleanup with partial-failure reports; `secure_delete` on SQLite; DB excluded from backup | `Persistence`, `PrivacyKit` | AT03, AT04, AT05 tests |
| Unauthorised device access / stale snapshots | Content concealed on `inactive` before the app-switcher snapshot; lock overlay before cleanup | `PrivacyKit/SessionLock.swift`, `RootView` | AT10: `concealsBeforeCleanup` |
| Misleading VPN status | "Protected by WARP" only when Kage's tunnel is connected and Cloudflare's trace reports `warp=on`/`plus` | `AppShell/Core/NetworkProtection.swift` | AT16: `unknownNeverClaimsProtection`, `NetworkProtectionMonitorTests` |
| Tracking | `WKContentRuleListStore` rules; strict mode blocks third-party cookies; clean-link copying | `SecurityKit/ContentBlocking.swift`, `CleanLinks.swift` | `ContentRuleBuilderTests`, `CleanLinksTests` |
| Insecure TLS | Platform validation only; certificate errors stop the load with a clear message; no bypass | `TabController` | Manual |
| Logs leaking secrets | No analytics; credential type redacts itself | `SecurityKit` | `credentialDescriptionRedactsToken` |

## Memory, root and what you're seeing (T-10 to T-14)

| ID | Threat | Control | Where | Test |
| --- | --- | --- | --- | --- |
| T-10 | Vault history and tabs read from the disk or a backup | Sealed per record with AES-256-GCM in a separate `Vault.sqlite`. Row ids are an HMAC of the URL or tab id, and kind and id are authenticated with each row. The key comes from the Secure Enclave (P-256 key agreement behind `.userPresence`, then HKDF); without an Enclave, a Keychain key behind `.userPresence`. Never synced, this device only. | `Persistence/VaultStore.swift`, `SecurityKit/VaultKey.swift` | `VaultStoreTests.nothingReadableOnDisk`, `wrongKeyReadsNothing`, `swappedRowsFailAuthentication`, `lockedVaultRefusesReadsAndWritesButStillDeletes` |
| T-11 | Memory read after Kage locks or goes to the background | On every lock, right after concealment: every WebView is released so WebKit ends the content processes; page snapshots are dropped; the URL cache and the in-memory AI conversation are cleared. The Vault locks on lock, on leaving it and on every trip to the background: its tabs leave memory (back/forward state included), the key is forgotten, and its WebKit disk, memory and fetch caches are emptied. | `PrivacyKit/SessionLock.swift` (`onLock`), `AppEnvironment.purgeForLock`/`lockVault`, `BrowserTabStore.purgeLiveContent`/`unload` | `SessionLockTests.lockRunsPurgeHookAfterConcealing`, `InMemoryVaultKey` tests |
| T-12 | Secrets in memory, swap, core files or under a debugger | Secrets are decoded from the Keychain per use and the raw bytes zeroed straight after; `SecureBytes` is `mlock`ed and zeroed with `memset_s`. Release builds call `ptrace(PT_DENY_ATTACH)` and every build sets `RLIMIT_CORE` to 0, in the app and in the tunnel extension. Kage's data folder is `completeUnlessOpen` on iOS. | `SecurityKit/SecureMemory.swift`, `ProcessHardening.swift`, `Keychain.swift`, `NetworkTunnel/TunnelKeychain.swift`, `Persistence/SQLiteStore.swift` | `SecureBytesTests`, `ProcessHardeningTests` |
| T-13 | The network sees which sites you visit | With the tunnel on, the local network and the ISP see only an encrypted WireGuard flow to the provider. With it off, Kage offers system encrypted DNS (DoH to Cloudflare 1.1.1.1) and WebKit upgrades known hosts to HTTPS. | `AppShell/Core/EncryptedDNS.swift`, `NetworkProtection.swift`, `WebViewFactory` | Device check |
| T-14 | Someone records or mirrors the screen | iOS: pages are covered while the scene is recorded, mirrored or on AirPlay, always in Private and Vault and everywhere with "Always hide Kage from screen capture". macOS: the window's `sharingType` is `.none` in those cases. The app-switcher snapshot is concealed (see above). | `AppShell/Views/CaptureShield.swift` | Device check |

### What an attacker with root can and can't get

Root on a running, unlocked device can read any process's memory, and no app can stop that. These controls narrow the window and make the rest of the device useless to the attacker. They are not a promise that a root attacker sees nothing.

| Attacker has | Gets | Doesn't get |
| --- | --- | --- |
| Root while Kage is open and unlocked | What's on screen and in the live web content processes; the Vault key while the Vault is open; a secret while it's in use (WebKit and WireGuard hold their own copies we can't wipe) | Nothing more than the user is looking at: there is no plaintext Vault on disk, and secrets aren't cached between uses |
| Root after Kage locked or went to the background | Standard tab URLs and titles (the tab list survives a lock), and Standard and Ghost history in `Kage.sqlite` | Live pages and snapshots (released), the AI conversation, the URL cache, anything in the Vault (key gone; rows sealed), keys from the Secure Enclave (it never releases them) |
| A copy of the disk or a backup | `Kage.sqlite` only if copied while the device was unlocked (it's `completeUnlessOpen` and excluded from backups) | The Vault in any state: it needs the device's Secure Enclave and the user's face, finger or passcode |
| A debugger on a release build | Only by first patching out `PT_DENY_ATTACH`, which needs root or a re-signed app | Core files: there are none |
| The local network or ISP, tunnel on | That you use a VPN, and how much data | Hostnames, sites, page contents |
| The local network or ISP, tunnel off | Destination IPs and TLS server names; hostnames too unless Encrypted DNS is on | Page contents and paths (HTTPS) |
| Someone recording or mirroring the screen | Kage's chrome; page content in Standard and Ghost unless the setting is on | Page content in Private and Vault |

Known limits:

- WebKit keeps cookies and site storage for persistent profiles (Vault included) in its own files. iOS Data Protection encrypts them, and "Forget" removes them, but Kage can't seal them itself.
- macOS: some screen-capture tools ignore `NSWindow.sharingType`. The Mac also has no app-switcher snapshot to conceal.
- Encrypted DNS is a system setting the user has to turn on once in Settings; Kage can install it but not enable it.

Open items: ruleset integrity checks for downloaded lists (none are downloaded yet), and a security review of the final build.
