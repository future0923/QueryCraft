import SwiftUI

struct WorkspaceStatementResultTabs: View {
    static let height: CGFloat = 40

    let results: [WorkspaceStatementResult]
    @Binding var selection: Int
    @Binding var section: WorkspaceSQLResultSection
    @State private var viewportWidth: CGFloat = 0
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            if showsNavigation {
                Button(
                    AppCopy.current.text(
                        "上一条语句结果",
                        "Previous Statement Result"
                    ),
                    systemImage: "chevron.left",
                    action: selectPrevious
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(section != .statement || selection == results.first?.id)
                .help(
                    AppCopy.current.text(
                        "上一条语句结果",
                        "Previous Statement Result"
                    )
                )
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        reportTab(
                            AppCopy.current.text("消息", "Messages"),
                            section: .messages
                        )
                        .id("messages")
                        reportTab(
                            AppCopy.current.text("摘要", "Summary"),
                            section: .summary
                        )
                        .id("summary")
                        ForEach(results) { result in
                            tab(for: result)
                                .id(result.statement.index)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        contentWidth = width
                    }
                }
                .scrollIndicators(.hidden)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    viewportWidth = width
                }
                .onChange(of: selection) { _, selection in
                    if section == .statement {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
                .onChange(of: section) { _, section in
                    switch section {
                    case .messages: proxy.scrollTo("messages", anchor: .leading)
                    case .summary: proxy.scrollTo("summary", anchor: .leading)
                    case .statement: proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }

            if showsNavigation {
                Button(
                    AppCopy.current.text("下一条语句结果", "Next Statement Result"),
                    systemImage: "chevron.right",
                    action: selectNext
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(section != .statement || selection == results.last?.id)
                .help(
                    AppCopy.current.text("下一条语句结果", "Next Statement Result")
                )
            }
        }
    }

    private var showsNavigation: Bool {
        viewportWidth > 0 && contentWidth > viewportWidth + 1
    }

    private func tab(for result: WorkspaceStatementResult) -> some View {
        let isSelected = section == .statement && selection == result.statement.index
        return Button {
            section = .statement
            selection = result.statement.index
        } label: {
            HStack(spacing: 6) {
                Image(systemName: result.state.statementResultSymbol)
                    .foregroundStyle(result.state.statementResultSymbolColor)
                    .frame(width: 14)
                Text(
                    AppCopy.current.text(
                        "结果 \((results.firstIndex { $0.id == result.id } ?? 0) + 1)",
                        "Result \((results.firstIndex { $0.id == result.id } ?? 0) + 1)"
                    )
                )
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Color.accentColor : .clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(
            AppCopy.current.text(
                "显示此语句的结果",
                "Shows this statement's result"
            )
        )
    }

    private func selectPrevious() {
        guard let index = results.firstIndex(where: { $0.id == selection }), index > 0
        else { return }
        section = .statement
        selection = results[index - 1].id
    }

    private func selectNext() {
        guard let index = results.firstIndex(where: { $0.id == selection }),
            index + 1 < results.count else { return }
        section = .statement
        selection = results[index + 1].id
    }

    private func reportTab(
        _ title: String,
        section target: WorkspaceSQLResultSection
    ) -> some View {
        Button {
            section = target
        } label: {
            Text(title)
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .frame(height: Self.height)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(section == target ? Color.accentColor : .clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(section == target ? .isSelected : [])
    }
}

private extension WorkspaceQueryExecutionState {
    var statementResultSymbol: String {
        switch self {
        case .idle:
            "clock"
        case .running:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .stopped:
            "stop.circle"
        case .completed:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .skipped:
            "forward.end"
        }
    }

    var statementResultSymbolColor: Color {
        switch self {
        case .running:
            .accentColor
        case .stopped:
            .orange
        case .completed:
            .green
        case .failed:
            .red
        case .idle, .skipped:
            .secondary
        }
    }
}
