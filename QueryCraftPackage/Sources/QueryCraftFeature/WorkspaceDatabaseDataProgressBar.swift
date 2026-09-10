import SwiftUI

struct WorkspaceDatabaseDataProgressBar: View {
    let isActive: Bool
    var accessibilityLabel: String? = nil

    var body: some View {
        ZStack {
            Divider()

            if isActive {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(
                        accessibilityLabel ?? AppCopy.current.text(
                            "正在获取数据",
                            "Fetching Data"
                        )
                    )
            }
        }
        .frame(height: 3)
        .clipped()
        .accessibilityHidden(!isActive)
    }
}
