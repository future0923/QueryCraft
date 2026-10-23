import SwiftUI
import QueryCraftMobileCore

/// Only the source adapter is mobile-specific; matching, ordering, cancellation,
/// limits, and next/previous behavior are the actual desktop implementation.
struct MobileGridSearchSource: WorkspaceGridSearchDataSource {
    let revision: UUID
    let data: MobileGridData
    var columns: [WorkspaceDatabaseDataColumn] {
        data.columns.enumerated().map { .init(id: $0.offset, name: $0.element) }
    }
    var rowCount: Int { data.rows.count }
    func row(at index: Int) -> WorkspaceDatabaseDataRow? {
        guard data.rows.indices.contains(index) else { return nil }
        return .init(id: index, values: data.columns.indices.map { data.cell(row: index, column: $0) })
    }
}

struct MobileGridSearchBar: View {
    @Bindable var controller: WorkspaceGridSearchController
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("查找列", selection: $controller.selectedDataColumnIndex) {
                    Text("所有列").tag(Int?.none)
                    ForEach(controller.columns) { column in Text(column.name).tag(Optional(column.id)) }
                }
                Picker("匹配方式", selection: $controller.searchOperator) {
                    ForEach(WorkspaceGridSearchOperator.allCases) { Text($0.title).tag($0) }
                }
                Toggle("区分大小写", isOn: $controller.isCaseSensitive)
                Button("结束查找", systemImage: "xmark") { focused = false; controller.dismiss() }
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }.accessibilityLabel("查找选项").accessibilityIdentifier("gridFindOptions")
            TextField("查找已加载数据", text: $controller.query)
                .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused).submitLabel(.search).onSubmit { controller.selectNextMatch() }
                .accessibilityIdentifier("gridFindText")
            ZStack {
                Text(controller.matchStatus).font(.caption2).monospacedDigit().lineLimit(1)
                    .opacity(controller.isSearching ? 0 : 1)
                ProgressView().controlSize(.mini).opacity(controller.isSearching ? 1 : 0)
            }.frame(width: 62).accessibilityLabel(controller.matchStatus)
            Button { controller.selectPreviousMatch() } label: {
                Image(systemName: "chevron.up").frame(width: 44, height: 44)
            }.disabled(controller.matches.isEmpty || controller.isSearching)
                .accessibilityLabel("上一个匹配项").keyboardShortcut("g", modifiers: [.command, .shift])
            Button { controller.selectNextMatch() } label: {
                Image(systemName: "chevron.down").frame(width: 44, height: 44)
            }.disabled(controller.matches.isEmpty || controller.isSearching)
                .accessibilityLabel("下一个匹配项").keyboardShortcut("g", modifiers: .command)
            Button {
                if focused { focused = false } else { controller.dismiss() }
            } label: {
                Image(systemName: focused ? "keyboard.chevron.compact.down" : "xmark").frame(width: 44, height: 44)
            }.accessibilityLabel(focused ? "收起键盘" : "结束查找").keyboardShortcut(.escape, modifiers: [])
        }.buttonStyle(.plain).padding(.horizontal, 4).frame(height: 44)
            .background(.bar)
            .accessibilityIdentifier("gridFindBar")
            .onChange(of: controller.focusRequest, initial: true) { _, _ in
                #if DEBUG
                // Programmatic render probes show the state after keyboard dismissal;
                // they do not synthesize input or dismiss Simulator onboarding UI.
                if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_GRID_FIND"]?.isEmpty == false { return }
                #endif
                focused = true
            }
            .onDisappear { focused = false }
    }
}
