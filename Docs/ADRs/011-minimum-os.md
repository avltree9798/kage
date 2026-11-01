# ADR-011: Minimum OS and iPhone Duo

**Status:** Accepted, 2026-11-01

## Decision

Kage supports iOS and iPadOS 27.2 and later only. iPhone Duo support is required for launch, not conditional.
macOS is assumed to target macOS 27; this is not yet confirmed.

## Consequences

- Every WebKit API in the M0 feasibility matrix (including `WKWebsiteDataStore(forIdentifier:)`) is available, so no availability checks are needed for them.
- The Duo hinge, posture and second-panel APIs in the iOS 27.2 SDK must be confirmed in M0 (ticket K-02) before the Duo adapter is written.
- Adaptive Canvas/Context layout (K-27, K-28) moves from M5 to M2.
- Amends ADR-007: the two-pane layout remains the fallback, but Duo-specific behaviour is in scope for 1.0.
