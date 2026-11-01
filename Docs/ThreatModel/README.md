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
| Misleading VPN status | Only `verifiedConnected` shows a shield, and nothing produces it today | `AppShell/Core/NetworkProtection.swift` | AT16: `unknownNeverClaimsProtection` |
| Tracking | `WKContentRuleListStore` rules; strict mode blocks third-party cookies; clean-link copying | `SecurityKit/ContentBlocking.swift`, `CleanLinks.swift` | `ContentRuleBuilderTests`, `CleanLinksTests` |
| Insecure TLS | Platform validation only; certificate errors stop the load with a clear message; no bypass | `TabController` | Manual |
| Logs leaking secrets | No analytics; credential type redacts itself | `SecurityKit` | `credentialDescriptionRedactsToken` |

Open items: ruleset integrity checks for downloaded lists (none are downloaded yet), and a security review of the final build.
