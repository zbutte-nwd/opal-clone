import SwiftUI

struct StatusBanner: View {
    enum Style { case ok, info, warning, error
        var color: Color { switch self { case .ok: .green; case .info: .blue; case .warning: .orange; case .error: .red } }
        var icon: String { switch self { case .ok: "checkmark.shield.fill"; case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" } }
    }
    var style: Style
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.icon).foregroundStyle(style.color).font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                if let actionTitle, let action {
                    Button(actionTitle, action: action).font(.subheadline.weight(.semibold)).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(style.color.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    VStack {
        StatusBanner(style: .ok, title: "Protected", message: "Screen Time access is on.")
        StatusBanner(style: .error, title: "Access revoked", message: "Blocking is off.", actionTitle: "Fix", action: {})
    }.padding()
}
