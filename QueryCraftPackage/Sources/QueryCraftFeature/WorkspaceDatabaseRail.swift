import SwiftUI

struct WorkspaceDatabaseRail: View {
    static let width: CGFloat = 80

    @Environment(\.colorScheme) private var colorScheme

    let contexts: [WorkspaceDatabaseContextDescriptor]
    let selectedContextID: UUID
    let selectContext: @MainActor (UUID) -> Void
    let closeContext: @MainActor (UUID) -> Void
    let closeOtherContexts: @MainActor (UUID) -> Void
    let moveContextToNewWindow: @MainActor (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(contexts) { context in
                Button {
                    selectContext(context.id)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: statusImage(for: context))
                            .font(.title3)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.primary)
                        Text(
                            context.databaseName
                                ?? AppCopy.current.text("未选择", "No Database")
                        )
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.center)
                        .frame(height: 30, alignment: .top)
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.primary)
                .workspaceDatabaseRailSelectionSurface(
                    isSelected: context.id == selectedContextID
                )
                .accessibilityLabel(
                    context.databaseName
                        ?? AppCopy.current.text("未选择数据库", "No Database")
                )
                .accessibilityIdentifier(
                    "databaseContext.\(context.databaseName ?? "none")"
                )
                .help(
                    context.databaseName
                        ?? AppCopy.current.text("未选择数据库", "No Database")
                )
                .contextMenu {
                    Button(
                        AppCopy.current.text("关闭连接", "Close Connection"),
                        systemImage: "xmark"
                    ) {
                        closeContext(context.id)
                    }
                    Button(
                        AppCopy.current.text(
                            "关闭其他连接",
                            "Close Other Connections"
                        ),
                        systemImage: "xmark.circle"
                    ) {
                        closeOtherContexts(context.id)
                    }
                    .disabled(contexts.count <= 1)
                    Divider()
                    Button(
                        AppCopy.current.text(
                            "将标签移到新窗口",
                            "Move Tab to New Window"
                        ),
                        systemImage: "macwindow.on.rectangle"
                    ) {
                        moveContextToNewWindow(context.id)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .workspaceDatabaseRailBackground(colorScheme: colorScheme)
    }

    static func backgroundSeparationOpacity(
        for colorScheme: ColorScheme
    ) -> Double {
        colorScheme == .dark ? 0.05 : 0.08
    }

    private func statusImage(
        for context: WorkspaceDatabaseContextDescriptor
    ) -> String {
        switch context.connectionState {
        case .connecting:
            "cylinder.badge.clock"
        case .connected:
            "cylinder"
        case .failed:
            "exclamationmark.icloud"
        }
    }
}

private extension View {
    @ViewBuilder
    func workspaceDatabaseRailSelectionSurface(
        isSelected: Bool
    ) -> some View {
        if #available(macOS 26.0, *) {
            background(
                isSelected
                    ? Color(nsColor: .controlBackgroundColor)
                    : Color.clear
            )
        } else {
            background(
                isSelected
                    ? Color(
                        nsColor:
                            .unemphasizedSelectedContentBackgroundColor
                    )
                    : Color.clear,
                in: .rect(cornerRadius: 6)
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    func workspaceDatabaseRailBackground(
        colorScheme: ColorScheme
    ) -> some View {
        if #available(macOS 26.0, *) {
            background {
                Color(nsColor: .controlBackgroundColor)
                    .overlay(
                        Color.primary.opacity(
                            WorkspaceDatabaseRail
                                .backgroundSeparationOpacity(
                                    for: colorScheme
                                )
                        )
                    )
            }
        } else {
            background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .trailing) {
                    Divider()
                }
        }
    }
}
