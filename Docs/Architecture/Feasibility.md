# K-02 status: iOS 27.2 and Duo API verification

**Not complete.** The GitHub macOS runners used by CI ship Xcode 26.x, so the iOS 27.2 SDK could not be inspected or built against from this repository. No public hinge, posture or second-panel API is assumed anywhere in the code.

What is in place:

- `PlatformAdapters.HingeSignalSource` is the single point where a real Duo API plugs in. `DuoCapabilityAdapter` reports `supportsHingeObservation = false` until one is registered.
- Layout already handles posture, hinge orientation and an occlusion range (`LayoutResolver.split`), so a real signal only has to fill `LayoutGeometry`.

To finish K-02: on a Mac with Xcode 27.2, search the UIKit and SwiftUI headers for posture, hinge and display-region APIs, implement a `HingeSignalSource` with them, and test on Duo hardware.
