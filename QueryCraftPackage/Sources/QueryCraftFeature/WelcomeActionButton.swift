import SwiftUI

struct WelcomeActionButton: View {
    let title: String
    let systemImage: String
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.horizontal, 12)
                .background(.quaternary, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .overlay {
            Capsule()
                .stroke(Color.accentColor.opacity(isFocused ? 0.62 : 0), lineWidth: 3)
                .padding(-2)
        }
    }
}
