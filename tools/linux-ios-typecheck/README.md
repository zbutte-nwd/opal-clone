# linux-ios-typecheck

Type-checks the iOS-only Swift (TetherKit, the Monitor/Push/ShieldAction/ShieldConfig extensions,
and the app's non-SwiftUI files) **on Linux**, against hand-written shims of FamilyControls,
ManagedSettings, ManagedSettingsUI, DeviceActivity, UserNotifications, BackgroundTasks, Security,
Combine, UIKit and os whose signatures mirror the real iOS 18 SDK. Built during the W8 audit.

```bash
make typecheck-ios-linux     # = ./sync.sh && swift build && swift test
```

Limits: shims are only as accurate as their author — the real compiler on a Mac is authoritative.
If the Mac build disagrees with a shim, **fix the shim** so this stays useful for Linux agents.
SwiftUI views and the Report extension are not covered.
