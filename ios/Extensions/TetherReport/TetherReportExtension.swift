// TetherReport — DeviceActivityReport extension. Runs sandboxed: no network, and the
// numbers it computes cannot leave the device (PLATFORM_CONSTRAINTS §6).
// W7: link TetherKit into this extension (it supplies `DeviceActivityReport.Context.totalActivity`).

import DeviceActivity
import SwiftUI
import TetherKit

@main
struct TetherReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        TotalActivityReport { summary in
            TotalActivityView(summary: summary)
        }
    }
}
