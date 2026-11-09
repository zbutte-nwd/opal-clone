#if os(iOS) && canImport(DeviceActivity)
import SwiftUI
import DeviceActivity

// Shared by the app (which embeds `DeviceActivityReport(.totalActivity, filter:)`) and the
// TetherReport extension (which declares a scene with the same context).
// NOTE for W7: TetherKit must be linked into the TetherReport extension AND the app.
extension DeviceActivityReport.Context {
    /// W8-audited: identical to Apple's Device Activity Report template (`Self("Total Activity")`).
    public static let totalActivity = Self("Total Activity")
}
#endif
