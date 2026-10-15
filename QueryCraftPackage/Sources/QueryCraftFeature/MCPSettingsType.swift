import SwiftUI

/// Use the same semantic typography as the other native settings panes.
enum MCPSettingsType {
    static let body = Font.body
    static let detail = Font.caption
}

struct MCPSettingsControlLabel: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(MCPSettingsType.body)
            Text(description).font(MCPSettingsType.detail).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
