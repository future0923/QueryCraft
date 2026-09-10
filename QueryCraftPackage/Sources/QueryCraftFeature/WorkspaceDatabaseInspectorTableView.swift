import SwiftUI

struct WorkspaceDatabaseInspectorTableView: View {
    let selection: WorkspaceDatabaseObjectSelection
    let detailsState: WorkspaceDatabaseObjectDetailsState
    let searchText: String
    let retry: @MainActor () -> Void

    var body: some View {
        switch detailsState {
        case .notLoaded, .loading:
            ProgressView(
                AppCopy.current.text(
                    "正在加载表信息…",
                    "Loading table information..."
                )
            )
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            ContentUnavailableView {
                Label(
                    AppCopy.current.text(
                        "无法加载表信息",
                        "Unable to Load Table Information"
                    ),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            } actions: {
                Button(
                    AppCopy.current.text("重试", "Retry"),
                    systemImage: "arrow.clockwise",
                    action: retry
                )
            }

        case let .loaded(details):
            tableInformation(details.tableInformation)
        }
    }

    private func tableInformation(
        _ information: WorkspaceDatabaseTableInformation?
    ) -> some View {
        let comment = information?.comment ?? ""
        let details = detailItems(information).filter(matchesSearch)
        let sizes = sizeItems(information).filter(matchesSearch)
        let showsComment = !comment.isEmpty
            && matchesSearch(
                MetadataItem(
                    id: "comment",
                    label: AppCopy.current.text("备注", "Comment"),
                    value: comment
                )
            )

        return List {
            if showsComment {
                Section {
                    metadataValue(comment, allowsMultipleLines: true)
                        .listRowSeparator(.hidden)
                } header: {
                    Text(AppCopy.current.text("备注", "COMMENT"))
                }
            }

            if !details.isEmpty {
                Section {
                    ForEach(details) { item in
                        metadataRow(item)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(AppCopy.current.text("表信息", "TABLE"))
                }
            }

            if !sizes.isEmpty {
                Section {
                    ForEach(sizes) { item in
                        metadataRow(item)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(AppCopy.current.text("大小", "SIZE"))
                }
            }

            if !searchText.isEmpty && !showsComment && details.isEmpty
                && sizes.isEmpty
            {
                Text(
                    AppCopy.current.text(
                        "没有匹配的表信息",
                        "No matching table information"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func metadataRow(_ item: MetadataItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.label)
                .font(.subheadline)
                .lineLimit(1)
                .help(item.label)

            metadataValue(item.value)
        }
    }

    private func metadataValue(
        _ value: String,
        allowsMultipleLines: Bool = false
    ) -> some View {
        WorkspaceInspectorMetadataValue(value: value, allowsMultipleLines: allowsMultipleLines)
    }

    private func detailItems(
        _ information: WorkspaceDatabaseTableInformation?
    ) -> [MetadataItem] {
        [
            MetadataItem(
                id: "engine",
                label: AppCopy.current.text("表引擎", "Table Engine"),
                value: formatMetadata(information?.engine)
            ),
            MetadataItem(
                id: "collation",
                label: AppCopy.current.text("排序规则", "Collation"),
                value: formatMetadata(information?.collation)
            ),
            MetadataItem(
                id: "rowFormat",
                label: AppCopy.current.text("行格式", "Row Format"),
                value: formatMetadata(information?.rowFormat)
            ),
            MetadataItem(
                id: "estimatedRows",
                label: AppCopy.current.text("预估行数", "Estimated Rows"),
                value: formatCount(information?.estimatedRowCount)
            ),
            MetadataItem(
                id: "nextAutoIncrement",
                label: AppCopy.current.text(
                    "下一个自增值",
                    "Next Auto-Increment"
                ),
                value: information?.nextAutoIncrement.map(formatCount)
                    ?? AppCopy.current.text("无", "None")
            ),
            MetadataItem(
                id: "creationTime",
                label: AppCopy.current.text("创建时间", "Created"),
                value: formatMetadata(information?.creationTime)
            ),
            MetadataItem(
                id: "updateTime",
                label: AppCopy.current.text("更新时间", "Updated"),
                value: formatMetadata(information?.updateTime)
            ),
        ]
    }

    private func sizeItems(
        _ information: WorkspaceDatabaseTableInformation?
    ) -> [MetadataItem] {
        [
            MetadataItem(
                id: "dataSize",
                label: AppCopy.current.text("数据大小", "Data Size"),
                value: formatSize(information?.dataSize)
            ),
            MetadataItem(
                id: "indexSize",
                label: AppCopy.current.text("索引大小", "Index Size"),
                value: formatSize(information?.indexSize)
            ),
            MetadataItem(
                id: "totalSize",
                label: AppCopy.current.text("总大小", "Total Size"),
                value: formatSize(information?.totalSize)
            ),
        ]
    }

    private func matchesSearch(_ item: MetadataItem) -> Bool {
        searchText.isEmpty
            || item.label.localizedStandardContains(searchText)
            || item.value.localizedStandardContains(searchText)
    }

    private func formatSize(_ byteCount: Int64?) -> String {
        guard let byteCount else {
            return AppCopy.current.text("不可用", "Unavailable")
        }
        return ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    private func formatMetadata(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return AppCopy.current.text("不可用", "Unavailable")
        }
        return value
    }

    private func formatCount(_ value: Int64?) -> String {
        guard let value else {
            return AppCopy.current.text("不可用", "Unavailable")
        }
        return value.formatted(.number.grouping(.automatic))
    }

    private struct MetadataItem: Identifiable {
        let id: String
        let label: String
        let value: String
    }
}
