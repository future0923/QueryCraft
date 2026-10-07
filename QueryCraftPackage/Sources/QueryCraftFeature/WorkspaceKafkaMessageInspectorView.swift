import AppKit
import SwiftUI

struct WorkspaceKafkaMessageInspectorView: View {
    let context: WorkspaceKafkaMessageInspectorContext
    let searchText: String

    var body: some View {
        if let row = context.row {
            message(row)
        } else {
            ContentUnavailableView(
                AppCopy.current.text("未选择消息", "No Message Selected"),
                systemImage: "text.bubble",
                description: Text(
                    AppCopy.current.text(
                        "选择一行 Kafka 消息以查看元数据和原始值。",
                        "Select one Kafka message to inspect its metadata and raw value."
                    )
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ row: WorkspaceDatabaseDataRow) -> some View {
        let fields = metadataFields(for: row)
        let rawValue = valueText(for: row, named: "value")
        let normalizedSearch = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let visibleFields = fields.filter { field in
            normalizedSearch.isEmpty
                || field.name.localizedCaseInsensitiveContains(normalizedSearch)
                || field.type.localizedCaseInsensitiveContains(normalizedSearch)
                || field.value.localizedCaseInsensitiveContains(normalizedSearch)
        }
        let showsRawValue = normalizedSearch.isEmpty
            || "value".localizedCaseInsensitiveContains(normalizedSearch)
            || "raw".localizedCaseInsensitiveContains(normalizedSearch)
            || rawValue.localizedCaseInsensitiveContains(normalizedSearch)
        let itemCount = visibleFields.count + (showsRawValue ? 1 : 0)

        return VStack(spacing: 0) {
            HStack {
                Text(AppCopy.current.text("Kafka 消息", "Kafka Message"))
                Spacer()
                Text(context.topic)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(context.topic)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)

            Divider()

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(visibleFields, id: \.name) { field in
                            metadataField(field)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if showsRawValue {
                            rawValueField(rawValue)
                        }

                        if itemCount == 0 && !normalizedSearch.isEmpty {
                            Text(
                                AppCopy.current.text(
                                    "没有匹配的消息字段",
                                    "No matching message fields"
                                )
                            )
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                        }
                    }
                    .padding(12)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func metadataFields(
        for row: WorkspaceDatabaseDataRow
    ) -> [(name: String, type: String, value: String)] {
        ["partition", "offset", "timestamp", "key", "headers"].compactMap {
            name in
            guard let column = context.columns.first(where: { $0.name == name })
            else { return nil }
            return (
                name: name,
                type: column.type ?? "",
                value: valueText(row.value(at: column.id))
            )
        }
    }

    private func valueText(
        for row: WorkspaceDatabaseDataRow,
        named name: String
    ) -> String {
        guard let column = context.columns.first(where: { $0.name == name })
        else { return "NULL" }
        return valueText(row.value(at: column.id))
    }

    private func valueText(_ cell: WorkspaceDatabaseDataCell) -> String {
        switch cell {
        case .null:
            "NULL"
        case let .text(value):
            value
        case let .binary(byteCount, _):
            "<BINARY \(byteCount) bytes>"
        }
    }

    private func metadataField(
        _ field: (name: String, type: String, value: String)
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldHeader(name: field.name, type: field.type)

            Text(field.value)
                .font(.subheadline)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor))
                }
                .help(field.value)
        }
    }

    private func rawValueField(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                fieldHeader(name: "value", type: "raw")

                WorkspaceInlineIconButton(
                    systemImageName: "doc.on.doc",
                    title: AppCopy.current.text("复制原始值", "Copy Raw Value"),
                    action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(value, forType: .string)
                    }
                )
            }

            WorkspaceReadOnlyTextView(
                text: value,
                usesMonospacedFont: true,
                accessibilityLabel: AppCopy.current.text(
                    "原始消息值",
                    "Raw Message Value"
                ),
                presentation: .automaticJSON
            )
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        }
    }

    private func fieldHeader(name: String, type: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
                .help(name)

            Spacer(minLength: 8)

            Text(type.isEmpty ? "text" : type)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .help(type)
        }
    }
}
