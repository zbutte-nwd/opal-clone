import DeviceActivity
import SwiftUI
import TetherKit

/// Plain values handed from `makeConfiguration` to the view.
struct ActivitySummary: Equatable {
    struct Item: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var duration: TimeInterval
    }
    var total: TimeInterval = 0
    var categories: [Item] = []
    var apps: [Item] = []
}

struct TotalActivityReport: DeviceActivityReportScene {
    // `.totalActivity` is defined in TetherKit/ReportContexts.swift so the app can embed
    // `DeviceActivityReport(.totalActivity, filter: …)` with the identical context.
    let context: DeviceActivityReport.Context = .totalActivity
    let content: (ActivitySummary) -> TotalActivityView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> ActivitySummary {
        var total: TimeInterval = 0
        var byCategory: [String: TimeInterval] = [:]
        var byApp: [String: TimeInterval] = [:]

        // VERIFY: the AsyncSequence nesting below against the iOS 17 SDK:
        // DeviceActivityResults<DeviceActivityData> -> .activitySegments -> .categories -> .applications
        for await deviceData in data {
            for await segment in deviceData.activitySegments {
                total += segment.totalActivityDuration
                for await categoryActivity in segment.categories {
                    let catName = categoryActivity.category.localizedDisplayName ?? "Other"
                    byCategory[catName, default: 0] += categoryActivity.totalActivityDuration
                    for await appActivity in categoryActivity.applications {
                        let appName = appActivity.application.localizedDisplayName
                            ?? appActivity.application.bundleIdentifier ?? "App"
                        byApp[appName, default: 0] += appActivity.totalActivityDuration
                    }
                }
            }
        }

        func top(_ m: [String: TimeInterval]) -> [ActivitySummary.Item] {
            m.map { ActivitySummary.Item(name: $0.key, duration: $0.value) }
                .sorted { $0.duration > $1.duration }
                .prefix(5).map { $0 }
        }
        return ActivitySummary(total: total, categories: top(byCategory), apps: top(byApp))
    }
}
