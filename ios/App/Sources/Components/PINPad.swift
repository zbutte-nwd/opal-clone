import SwiftUI

/// Custom numeric keypad. Deliberately NOT biometric: Tether never uses Face ID / Touch ID.
struct PINPad: View {
    @Binding var pin: String
    var maxDigits: Int = 8
    /// Number of dots drawn (grows with input beyond `minDigits`).
    var minDigits: Int = 6
    var errorMessage: String?

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                ForEach(0..<max(minDigits, pin.count), id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Color.primary : Color.clear)
                        .overlay(Circle().stroke(Color.secondary, lineWidth: 1.5))
                        .frame(width: 14, height: 14)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("PIN entry")
            .accessibilityValue("\(pin.count) digits entered")

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            VStack(spacing: 12) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 20) { ForEach(row, id: \.self) { key($0) } }
                }
                HStack(spacing: 20) {
                    Color.clear.frame(width: 72, height: 72)
                    key("0")
                    Button { if !pin.isEmpty { pin.removeLast() } } label: {
                        Image(systemName: "delete.left").font(.title2)
                            .frame(width: 72, height: 72)
                    }
                    .accessibilityLabel("Delete")
                    .disabled(pin.isEmpty)
                }
            }
        }
    }

    private func key(_ d: String) -> some View {
        Button {
            if pin.count < maxDigits { pin.append(d) }
        } label: {
            Text(d).font(.title).fontWeight(.medium)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d)
    }
}

#Preview {
    struct Wrapper: View { @State var pin = "123"; var body: some View { PINPad(pin: $pin) } }
    return Wrapper()
}
