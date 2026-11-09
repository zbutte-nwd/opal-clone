import SwiftUI
import DeviceActivity
import TetherCore
import TetherKit

/// F1–F2: system-rendered usage report (extension) + focus stats computed in-app.
struct InsightsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsGrid
                    Text("Screen time today").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    reportView
                    Text("Usage details are drawn by iOS in a sandboxed view. Tether and the server never receive per-app usage.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Insights")
        }
    }

    private var statsGrid: some View {
        let s = model.stats
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            stat("Focused today", Fmt.duration(minutes: s.focusedMinutesToday), "clock.fill")
            stat("Focused this week", Fmt.duration(minutes: s.focusedMinutesThisWeek), "calendar")
            stat("Sessions this week", "\(s.sessionsCompletedThisWeek)", "timer")
            stat("Streak", "\(s.currentStreakDays) day\(s.currentStreakDays == 1 ? "" : "s")", "flame.fill")
        }
    }

    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var reportView: some View {
        if model.platform.isStub {
            EmptyState(icon: "chart.bar.xaxis", title: "Report unavailable in the Simulator",
                       message: "The Screen Time report renders on a real device with Screen Time access.")
                .card()
        } else if model.screenTimeAuth != .approved {
            EmptyState(icon: "lock", title: "Screen Time access needed", message: "Allow Tether in Settings → Screen Time to see your usage.")
                .card()
        } else {
            DeviceActivityReport(.totalActivity, filter: Self.todayFilter())
                .frame(minHeight: 320)
        }
    }

    // NOTE: `DeviceActivityReport.Context.totalActivity` is declared by W5 (TetherKit/ReportContexts.swift) and must match the
    // context the TetherReport extension registers. Filter init: segment .daily(during:) with defaults for users/devices.
    static func todayFilter(now: Date = Date()) -> DeviceActivityFilter {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? now
        // Same argument shape as Apple's DeviceActivityReport sample (users/devices spelled out).
        return DeviceActivityFilter(segment: .daily(during: DateInterval(start: start, end: end)),
                                    users: .all,
                                    devices: .init([.iPhone]))
    }
}

#Preview("Insights") { InsightsView().environment(AppModel.preview()) }
