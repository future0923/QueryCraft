import SwiftUI

struct RedisKeySearchBar: View {
    @Binding var text: String
    @Binding var isExactSearch: Bool
    let submit: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            WorkspaceGridSearchField(
                text: $text,
                placeholder: AppCopy.current.text(
                    "输入后按 Enter 搜索",
                    "Press Enter to search"
                ),
                focusRequest: 0,
                submit: submit,
                cancel: cancel,
                accessibilityIdentifier: "sidebarSearchField"
            )
            .controlSize(.regular)
            .frame(maxWidth: .infinity)

            Toggle(
                AppCopy.current.text("精确搜索", "Exact Search"),
                isOn: $isExactSearch
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help(
                AppCopy.current.text(
                    "精确搜索使用 EXISTS；未勾选时使用 Redis SCAN MATCH，支持 Redis 通配符。",
                    "Exact search uses EXISTS; otherwise Redis SCAN MATCH supports Redis glob patterns."
                )
            )
            .accessibilityIdentifier("redisExactSearchToggle")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
