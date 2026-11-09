import SwiftUI
import TetherCore

struct GroupChip: View {
    let group: BlockGroup
    var selected: Bool = false
    var showLock: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: group.colorHex)).frame(width: 10, height: 10)
            Text(group.name).lineLimit(1)
            if showLock { Image(systemName: "lock.fill").font(.caption2) }
            if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
        }
        .font(.subheadline)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemFill)))
        .overlay(Capsule().stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Multi-select grid of group chips.
struct GroupChipPicker: View {
    let groups: [BlockGroup]
    @Binding var selection: Set<GroupID>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(groups) { g in
                Button {
                    if selection.contains(g.id) { selection.remove(g.id) } else { selection.insert(g.id) }
                } label: {
                    GroupChip(group: g, selected: selection.contains(g.id), showLock: g.source == .server)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
