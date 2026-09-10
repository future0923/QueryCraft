import SwiftUI

struct WorkspaceDatabaseObjectDetailBottomBar: View {
    let availableTabs: [WorkspaceDatabaseObjectDetailTab]
    let objectKind: WorkspaceDatabaseObjectKind
    @Binding var selectedTab: WorkspaceDatabaseObjectDetailTab
    let page: WorkspaceDatabaseDataPage?
    let countState: WorkspaceDatabaseDataCountState
    let isFetching: Bool
    let isStopped: Bool
    let previousPage: () -> Void
    let nextPage: () -> Void
    let loadRange: (_ limit: Int, _ offset: Int) -> Void
    let exportController: WorkspaceDataExportController
    let searchController: WorkspaceGridSearchController
    let isDataFilterPresented: Bool
    let hasActiveDataFilter: Bool
    let isDataFilterDisabled: Bool
    let toggleDataFilter: () -> Void
    let isAddRowVisible: Bool
    let isAddRowEnabled: Bool
    let addRowDisabledReason: String?
    let addRow: () -> Void
    let isAddColumnEnabled: Bool
    let addColumn: () -> Void
    let isAddIndexEnabled: Bool
    let addIndex: () -> Void
    var mappingActions: WorkspaceElasticsearchMappingActionsView? = nil

    @State private var showsRangeEditor = false
    @State private var draftLimit = WorkspaceDatabaseDataPage.defaultLimit
    @State private var draftOffset = 0

    var body: some View {
        ZStack {
            if selectedTab == .data {
                WorkspaceDatabaseDataRangeStatus(
                    page: page,
                    countState: countState,
                    isFetching: isFetching,
                    isStopped: isStopped
                )
            }

            HStack {
                WorkspaceDatabaseObjectDetailSegmentedControl(
                    tabs: availableTabs,
                    objectKind: objectKind,
                    selection: $selectedTab
                )
                .fixedSize()

                contextualAddControl

                Spacer()

                if selectedTab == .structure, objectKind.isElasticsearchDocumentResource {
                    mappingActions
                }

                if selectedTab == .data {
                    HStack(spacing: 8) {
                        WorkspaceDatabaseDataFilterControl(
                            isPresented: isDataFilterPresented,
                            hasActiveFilter: hasActiveDataFilter,
                            isDisabled: isDataFilterDisabled,
                            toggle: toggleDataFilter
                        )

                        if let page, page.rowCount > 0 {
                            HStack(spacing: 8) {
                                WorkspaceGridSearchControl(
                                    controller: searchController
                                )

                                WorkspaceDataExportControl(
                                    controller: exportController
                                )
                            }
                            .foregroundStyle(.primary)
                        }

                        if let page {
                            HStack(spacing: 4) {
                                Button(
                                    AppCopy.current.text("上一页", "Previous Page"),
                                    systemImage: "chevron.left",
                                    action: previousPage
                                )
                                .labelStyle(.iconOnly)
                                .disabled(page.offset == 0)
                                .help(AppCopy.current.text("上一页", "Previous Page"))

                                Button(
                                    AppCopy.current.text("页面范围", "Page Range"),
                                    systemImage: "gearshape",
                                    action: showRangeEditor
                                )
                                .labelStyle(.iconOnly)
                                .help(AppCopy.current.text("页面范围", "Page Range"))
                                .accessibilityIdentifier("databaseDataRangeButton")
                                .popover(
                                    isPresented: $showsRangeEditor,
                                    arrowEdge: .bottom
                                ) {
                                    WorkspaceDatabaseDataRangeEditor(
                                        limit: $draftLimit,
                                        offset: $draftOffset,
                                        apply: applyRange
                                    )
                                }

                                Button(
                                    AppCopy.current.text("下一页", "Next Page"),
                                    systemImage: "chevron.right",
                                    action: nextPage
                                )
                                .labelStyle(.iconOnly)
                                .disabled(
                                    isFetching || isStopped || !page.hasNextPage
                                )
                                .help(AppCopy.current.text("下一页", "Next Page"))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .accessibilityIdentifier("databaseObjectDetailBottomBar")
    }

    @ViewBuilder
    private var contextualAddControl: some View {
        switch selectedTab {
        case .data:
            if isAddRowVisible {
                Button(
                    objectKind.isElasticsearchDocumentResource
                        ? AppCopy.current.text("文档", "Document")
                        : AppCopy.current.text("行", "Row"),
                    systemImage: "plus",
                    action: addRow
                )
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!isAddRowEnabled)
                .help(addRowHelp)
                .accessibilityHint(addRowHelp)
                .accessibilityIdentifier("databaseDataAddRowButton")
            }
        case .structure:
            Button(
                objectKind.isElasticsearchDocumentResource
                    ? AppCopy.current.text("字段", "Field")
                    : AppCopy.current.text("字段", "Column"),
                systemImage: "plus",
                action: addColumn
            )
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!isAddColumnEnabled)
            .help(
                objectKind.isElasticsearchDocumentResource
                    ? AppCopy.current.text("新增字段（⌘I）", "Add Field (⌘I)")
                    : AppCopy.current.text(
                        "新增字段（⌘I）",
                        "Add Column (⌘I)"
                    )
            )
            .accessibilityIdentifier("databaseStructureAddColumnButton")
        case .indexes:
            Button(
                AppCopy.current.text("索引", "Index"),
                systemImage: "plus",
                action: addIndex
            )
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(!isAddIndexEnabled)
            .help(
                AppCopy.current.text(
                    "新增索引（⌘I）",
                    "Add Index (⌘I)"
                )
            )
            .accessibilityIdentifier("databaseIndexesAddIndexButton")
        case .options, .ddl:
            EmptyView()
        }
    }

    private var addRowHelp: String {
        if !isAddRowEnabled, let addRowDisabledReason {
            return addRowDisabledReason
        }
        if objectKind.isElasticsearchDocumentResource {
            return AppCopy.current.text(
                "新增文档（⌘I）",
                "Add Document (⌘I)"
            )
        }
        return AppCopy.current.text("新增行（⌘I）", "Add Row (⌘I)")
    }

    private func showRangeEditor() {
        guard let page else { return }
        draftLimit = page.limit
        draftOffset = page.offset
        showsRangeEditor = true
    }

    private func applyRange() {
        guard draftOffset >= 0, draftLimit > 0 else { return }
        showsRangeEditor = false
        loadRange(draftLimit, draftOffset)
    }
}

private extension WorkspaceDatabaseObjectKind {
    var isElasticsearchDocumentResource: Bool {
        self == .elasticsearchIndex
            || self == .elasticsearchAlias
            || self == .elasticsearchDataStream
    }
}
