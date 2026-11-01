# Kage (影) Browser

A native, privacy-first WebKit browser for iOS 27.2+, iPadOS 27.2+, iPhone Duo and macOS.
Persistent identity, ephemeral activity.

## Layout

| Path | Contents |
| --- | --- |
| `Apps/KageiOS`, `Apps/KageMac` | App entry points; `project.yml` generates the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| `Packages/` | Swift packages: KageModels, Persistence, SecurityKit, PrivacyKit, BrowserCore, ContextAI, PlatformAdapters, DesignSystem, AppShell |
| `Tests/` | Cross-package suites (integration, UI, security, performance). Unit tests live in each package |
| `Config/` | Model registry, privacy defaults, content rules |
| `Docs/` | Architecture, threat model, ADRs |

## Build

```sh
# Package tests (macOS)
for p in Packages/*/; do swift test --package-path "$p"; done

# Apps
brew install xcodegen && xcodegen generate && open Kage.xcodeproj
```

Requires Xcode with the iOS 27.2 and macOS 27 SDKs.

`Kage.xcodeproj` needs a paid Apple Developer team (Network Extensions, iCloud). With a free Personal Team, use the
local project instead: see [Docs/LocalDevelopment.md](Docs/LocalDevelopment.md).
