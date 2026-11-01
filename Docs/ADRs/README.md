# Architectural decision records

| ADR | Decision | Status |
| --- | --- | --- |
| 001 | Use `WKWebView`, not a custom rendering engine | Accepted (spec v3) |
| 002 | Store Kage navigation history separately from WebKit website data | Accepted (spec v3) |
| 003 | Keychain for Cloudflare credentials; no credentials in webpage JS | Accepted (spec v3) |
| 004 | Nonpersistent WebKit data stores for private sessions | Accepted (spec v3) |
| 005 | Protected logins are best-effort site-level data preservation | Accepted (spec v3) |
| 006 | AI automation is opt-in, with sensitive-site exclusions | Accepted (spec v3) |
| 007 | Responsive two-pane design as Duo baseline | Amended by 011 |
| 008 | Embedded WARP needs a separate feasibility and licensing decision | Accepted (spec v3) |
| 009 | SQLite for local data; CloudKit only for optional approved sync | Accepted (spec v3) |
| 010 | Privacy deletion is idempotent and reports partial failures | Accepted (spec v3) |
| 011 | Minimum OS iOS/iPadOS 27.2; iPhone Duo support required | [Accepted](011-minimum-os.md) |
