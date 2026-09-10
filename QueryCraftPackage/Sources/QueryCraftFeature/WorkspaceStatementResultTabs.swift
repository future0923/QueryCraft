import SwiftUI

struct WorkspaceStatementResultTabs: View {
    static let height: CGFloat = 40

    let results: [WorkspaceStatementResult]
    @Binding var selection: Int
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
                .disabled(selection == 0)
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
                    proxy.scrollTo(selection, anchor: .center)
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
                .disabled(selection >= results.count - 1)
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
        let isSelected = selection == result.statement.index
        return Button {
            selection = result.statement.index
        } label: {
            HStack(spacing: 6) {
                Image(systemName: result.state.statementResultSymbol)
                    .foregroundStyle(result.state.statementResultSymbolColor)
                    .frame(width: 14)
                Text(
                    AppCopy.current.text(
                        "语句 \(result.statement.index + 1)",
                        "Statement \(result.statement.index + 1)"
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
        selection = max(0, selection - 1)
    }

    private func selectNext() {
        selection = min(results.count - 1, selection + 1)
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
