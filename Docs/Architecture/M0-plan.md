# M0 plan

The working plan (API feasibility matrix, package interfaces, tickets K-01 to K-30, open questions) lives at
https://claude.ai/artifact/WBjJuHt5Sg5SWe56NaThUa

## Package graph

```text
AppShell ──► BrowserCore ──► PrivacyKit ──► Persistence ──► KageModels
   │              │               └───────► SecurityKit ──► KageModels
   ├──► ContextAI ─┴► Persistence, SecurityKit
   ├──► PlatformAdapters ──► KageModels
   └──► DesignSystem
```

WebKit objects live only in `@MainActor` types inside BrowserCore. Every other package exposes value types and `Sendable` protocols.
