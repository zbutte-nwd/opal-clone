import SwiftUI

struct CountdownRing<Center: View>: View {
    /// 0...1 fraction elapsed.
    var progress: Double
    var tint: Color = .accentColor
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: () -> Center

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, 1 - progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .padding(lineWidth / 2)
    }
}

#Preview {
    CountdownRing(progress: 0.3) { Text("14:20").font(.title.monospacedDigit()) }
        .frame(width: 140, height: 140)
}
