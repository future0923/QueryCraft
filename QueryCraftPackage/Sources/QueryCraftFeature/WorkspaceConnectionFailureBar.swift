import SwiftUI

struct WorkspaceConnectionFailureBar: View {
    let message: String
    let retry: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label(message, systemImage: "exclamationmark.triangle")
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(
                    AppCopy.current.text("重试", "Retry"),
                    systemImage: "arrow.clockwise",
                    action: retry
                )
            }
            .controlSize(.small)
            .padding()
        }
        .background(.bar)
    }
}
