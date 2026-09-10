import SwiftUI

struct WorkspaceToolbarConnectionStatusIcon: View {
    let state: WorkspaceConnectionState

    var body: some View {
        switch state {
        case .connecting:
            Label(
                AppCopy.current.text("正在连接", "Connecting"),
                systemImage: "ellipsis"
            )
            .foregroundStyle(.secondary)
        case .connected:
            Label(
                AppCopy.current.text("已连接", "Connected"),
                systemImage: "circle.fill"
            )
            .foregroundStyle(.green)
            .accessibilityIdentifier("workspaceConnected")
        case .failed:
            Label(
                AppCopy.current.text("连接已断开", "Disconnected"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.red)
        }
    }
}
