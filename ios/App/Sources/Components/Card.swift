import SwiftUI

extension View {
    /// Standard rounded card background used on Home / Insights.
    func card() -> some View {
        self.padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}
