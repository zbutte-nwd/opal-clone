import SwiftUI
import TetherCore

/// M T W T F S S chips. Binds a set of ISO weekdays (1 = Monday … 7 = Sunday).
struct WeekdayPicker: View {
    @Binding var days: Set<ISOWeekday>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(Fmt.initials[d - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Circle().fill(on ? Color.accentColor : Color(.secondarySystemFill)))
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Fmt.weekdayFull(d))
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
    }
}

#Preview {
    struct W: View { @State var d: Set<Int> = [1, 2, 3, 4, 5]; var body: some View { WeekdayPicker(days: $d).padding() } }
    return W()
}
