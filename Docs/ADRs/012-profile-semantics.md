# ADR-012: What each privacy profile preserves

**Status:** Accepted, 2026-11-01. Answers spec 24 Q3 and Q12.

## Decision

Each persistent profile gets its own WebKit store via `WKWebsiteDataStore(forIdentifier:)`. Protected sites are **not** split into their own stores: they are exempted from cleanup inside their profile's store, so single sign-on across identity providers keeps working.

| | Standard | Ghost | Vault | Private |
| --- | --- | --- | --- | --- |
| WebKit store | Persistent, own identifier | Persistent, own identifier | Persistent, own identifier | `nonPersistent()`, dropped at session end |
| Kage history | Kept for retention (default 24 h) | 15 min default | Until deleted | Never written |
| Protected sites | Selected storage kept; history kept | Same | Same | Not applicable |
| Tabs and session restore | Saved | Saved, thumbnails never taken | Saved | Not saved |
| AI chats | Saved locally | Never saved | Saved locally | Never saved; no automatic AI |
| Lock default | None | Lock and forget | Lock only, unlock to open | Lock and close session |
| Handoff | Allowed | Off | Off | Off |

## Consequences

- Cookies never cross profiles (AT06).
- Routine cleanup removes expired Kage rows exactly; WebKit data is only removed when the user turns on routine website-data cleanup or uses Forget Now, by site and type.
- Clear-all removes protected logins too and needs confirmation (AT05).
