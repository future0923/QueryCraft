import SwiftUI

struct WorkspaceDatabaseInspectorRowView: View {
    let fields: [WorkspaceDatabaseInspectorField]
    let searchText: String
    let isUpdatingLoadedValue: Bool
    let applyMutation: @MainActor (
        WorkspaceDatabaseInspectorField,
        WorkspaceDatabaseInspectorMutation
    ) -> Void

    var body: some View {
        let filteredFields = searchText.isEmpty
            ? fields
            : fields.filter {
                $0.name.localizedStandardContains(searchText)
                    || $0.type.localizedStandardContains(searchText)
                    || $0.searchableValue.localizedStandardContains(searchText)
            }

        List {
            Section {
                if filteredFields.isEmpty && !searchText.isEmpty {
                    Text(
                        AppCopy.current.text(
                            "没有匹配的字段",
                            "No matching fields"
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredFields) { field in
                        WorkspaceDatabaseInspectorFieldRow(
                            field: field,
                            isBusy: isUpdatingLoadedValue,
                            applyMutation: { mutation in
                                applyMutation(field, mutation)
                            }
                        )
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                HStack {
                    Text(AppCopy.current.text("字段", "Fields"))
                    Spacer()
                    Text("\(filteredFields.count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

private extension WorkspaceDatabaseInspectorField {
    var searchableValue: String {
        if hasMultipleValues {
            return AppCopy.current.text("多个值", "Multiple values")
        }
        return switch value {
        case .required:
            "REQUIRED"
        case .useDefault:
            "DEFAULT"
        case .null:
            "NULL"
        case let .text(value):
            WorkspaceDatabaseDataCell.boundedPreview(
                value,
                maximumCharacterCount: WorkspaceDatabaseInspectorField
                    .maximumSearchPreviewCharacters,
                truncationIndicator: ""
            )
        case let .binary(byteCount):
            "BINARY \(byteCount)"
        }
    }
}
