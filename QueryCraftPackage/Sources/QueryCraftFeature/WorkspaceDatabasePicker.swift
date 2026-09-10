import SwiftUI

struct WorkspaceDatabasePicker: View {
    let databaseNames: [String]
    let databaseKeyCounts: [String: Int]
    let selectedDatabaseName: String?
    let selectDatabase: @MainActor (String) -> Void
    let dismiss: @MainActor () -> Void

    @State private var searchText = ""
    @State private var selection: String?

    init(
        databaseNames: [String],
        databaseKeyCounts: [String: Int] = [:],
        selectedDatabaseName: String?,
        selectDatabase: @escaping @MainActor (String) -> Void,
        dismiss: @escaping @MainActor () -> Void
    ) {
        self.databaseNames = databaseNames
        self.databaseKeyCounts = databaseKeyCounts
        self.selectedDatabaseName = selectedDatabaseName
        self.selectDatabase = selectDatabase
        self.dismiss = dismiss
        _selection = State(
            initialValue: selectedDatabaseName ?? databaseNames.first
        )
    }

    private var filteredDatabaseNames: [String] {
        guard !searchText.isEmpty else { return databaseNames }
        return databaseNames.filter {
            $0.localizedStandardContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(AppCopy.current.text("打开数据库", "Open Database"))
                .font(.headline)

            WorkspaceGridSearchField(
                text: $searchText,
                placeholder: AppCopy.current.text(
                    "搜索数据库",
                    "Search databases"
                ),
                focusRequest: 1,
                submit: openSelection,
                cancel: dismiss,
                moveUp: { moveSelection(by: -1) },
                moveDown: { moveSelection(by: 1) }
            )
            .frame(height: 24)

            if filteredDatabaseNames.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(
                        filteredDatabaseNames,
                        id: \.self,
                        selection: $selection
                    ) { databaseName in
                        HStack(spacing: 12) {
                            Label(databaseName, systemImage: "cylinder")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.primary)

                            Spacer(minLength: 8)

                            if let keyCount = databaseKeyCounts[databaseName] {
                                Text(
                                    AppCopy.current.text(
                                        "\(keyCount.formatted()) 个 Key",
                                        "\(keyCount.formatted()) Keys"
                                    )
                                )
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            }
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .help(databaseName)
                            .tag(databaseName)
                            .id(databaseName)
                            .listRowSeparator(.hidden)
                            .onTapGesture(count: 2) {
                                open(databaseName)
                            }
                            .accessibilityIdentifier(
                                "databasePicker.\(databaseName)"
                            )
                    }
                    .listStyle(.inset)
                    .onChange(of: selection) { _, selection in
                        guard let selection else { return }
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
            }

            HStack {
                Button(
                    AppCopy.current.text("取消", "Cancel"),
                    action: dismiss
                )
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(
                    AppCopy.current.text("打开", "Open"),
                    action: openSelection
                )
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 420, height: 460)
        .onChange(of: databaseNames) {
            synchronizeSelection()
        }
        .onChange(of: searchText) {
            synchronizeSelection()
        }
    }

    private func openSelection() {
        guard let selection else { return }
        open(selection)
    }

    private func open(_ databaseName: String) {
        selectDatabase(databaseName)
        dismiss()
    }

    private func moveSelection(by offset: Int) {
        let names = filteredDatabaseNames
        guard !names.isEmpty else { return }

        let currentIndex = selection.flatMap { names.firstIndex(of: $0) }
        let proposedIndex: Int
        if let currentIndex {
            proposedIndex = currentIndex + offset
        } else {
            proposedIndex = offset < 0 ? names.count - 1 : 0
        }
        selection = names[min(max(proposedIndex, 0), names.count - 1)]
    }

    private func synchronizeSelection() {
        if let selection,
           filteredDatabaseNames.contains(selection)
        {
            return
        }
        if let selectedDatabaseName,
           filteredDatabaseNames.contains(selectedDatabaseName)
        {
            selection = selectedDatabaseName
        } else {
            selection = filteredDatabaseNames.first
        }
    }
}
