# K-02 status: iOS 27.2 and Duo API verification

**Done for the SDK; hardware check pending.** CI's `sdk-survey` job runs on GitHub's `xcode-27` image
(Xcode 27.2 RC, iOS 27.2 SDK, an `iPhone Duo` simulator device type) and prints the declarations below on every run.

## APIs Kage uses (iOS 27.1+, confirmed in the iOS 27.2 SDK, 2026-11-01)

| API | Declaration (SwiftUICore) | Use in Kage |
|---|---|---|
| Hinge state | `View.onHingeChange(isEnabled: Bool = true, _ action: (DeviceHingeContext, DeviceHingeContext) -> Void)` | `RootView` maps `DeviceHinge.status` (`.closed`, `.partiallyOpen`, `.fullyOpen`) to `HingeStatus` |
| Hinge value | `struct DeviceHinge { var status: Status; var angle: Angle }`, `DeviceHingeContext.hinge: DeviceHinge?` | `nil` means no fold; the angle isn't needed for layout |
| Fold region | `GeometryProxy.reservedRegions(kind: ReservedRegion.Kind, options: QueryOptions = [], layoutDirectionBehavior: .mirrors) -> [ReservedRegion]` | `.division` and `.occlusion` regions become `LayoutGeometry.hingeOcclusion` |
| Region value | `struct ReservedRegion { id; kind; frame: CGRect; margins: EdgeInsets; isActive: Bool }` | Inactive regions are ignored |

UIKit equivalents exist (`UIHingeInteraction`, `UIHinge` with the angle in radians, `UIView.reservedRegions(kind:options:)`),
as do `ArrangementView` / `UIArrangementViewController` and vertical toolbars. Kage's chrome is SwiftUI, so it uses the SwiftUI forms.
All are `anyAppleOS 27.1`; Kage's macOS floor is 27.0, so the calls are compiled for iOS only.

`PlatformAdapters.DuoSignals.geometry` turns these readings into `LayoutGeometry`; its tests cover open, half-folded
(desk-like), closed, occluded and no-hinge cases. `LayoutResolver` keeps every control out of the fold.

## Still open

- The `xcode-27` image ships iOS 27.0 and 27.1 simulator runtimes but not 27.2, so the app (floor 27.2) can't launch in a
  simulator there yet. The Duo layout is covered by unit tests and needs a run on the Duo simulator or hardware with iOS 27.2.
