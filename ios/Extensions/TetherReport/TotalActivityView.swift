import SwiftUI

struct TotalActivityView: View {
    let summary: ActivitySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen time")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Self.format(summary.total))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
            }
            if !summary.categories.isEmpty {
                section("Top categories", items: summary.categories)
            }
            if !summary.apps.isEmpty {
                section("Top apps", items: summary.apps)
            }
            if summary.total == 0 {
                Text("No activity recorded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func section(_ title: String, items: [ActivitySummary.Item]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(items) { item in
                HStack {
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text(Self.format(item.duration)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: max(interval, 0)).flatMap { $0.isEmpty ? nil : $0 } ?? "0m"
    }
}
