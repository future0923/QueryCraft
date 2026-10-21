import SwiftUI

struct MCPSettingsIndexView: View {
    let select: (MCPSettingsDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(copy("全部 MCP 设置", "All MCP settings")).font(.title2)
                    Spacer()
                    Button(copy("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text(copy("这里是设置目录。单击任一项目，跳转到对应设置。", "This is a settings directory. Click any row to go to that setting."))
                    .font(MCPSettingsType.detail).foregroundStyle(.secondary)
            }.padding(20)
            Form {
                ForEach(["access", "permissions", "activity"], id: \.self) { section in
                    Section(sectionTitle(section)) {
                        ForEach(MCPSettingsDestination.allCases.filter { $0.section == section }) { destination in
                            Button {
                                select(destination)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(destination.title)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityIdentifier("mcp.settings.index.\(destination.rawValue)")
                            .help(copy("单击跳转到此设置", "Click to go to this setting"))
                        }
                    }
                }
            }
            .formStyle(.grouped).scrollContentBackground(.hidden).contentMargins(.top, 8, for: .scrollContent)
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 460, idealHeight: 620)
    }

    private func sectionTitle(_ section: String) -> String {
        switch section {
        case "access": copy("接入", "Connection")
        case "activity": copy("调用记录", "Activity")
        default: copy("访问权限", "Access")
        }
    }
}
