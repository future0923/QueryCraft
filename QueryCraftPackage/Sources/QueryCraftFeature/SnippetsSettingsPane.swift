import SwiftUI

struct SnippetsSettingsPane: View {
    @State private var store = SQLSnippetStore.shared
    @State private var editorContext: SnippetEditorContext?

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(copy.snippetsDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(copy.addSnippet, systemImage: "plus") {
                    editorContext = SnippetEditorContext(snippet: nil)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if store.snippets.isEmpty {
                emptyState
            } else {
                snippetTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editorContext) { context in
            SnippetEditorSheet(store: store, snippet: context.snippet)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "curlybraces")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text(copy.snippetEmptyTitle)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(copy.snippetEmptyDescription)
                .font(.callout)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var snippetTable: some View {
        VStack(spacing: 0) {
            columnHeader

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.snippets.enumerated()), id: \.element.id) { index, snippet in
                        SnippetTableRow(
                            snippet: snippet,
                            copy: copy,
                            onToggle: { isEnabled in
                                var updated = snippet
                                updated.isEnabled = isEnabled
                                store.update(updated)
                            },
                            onEdit: {
                                editorContext = SnippetEditorContext(snippet: snippet)
                            },
                            onDelete: {
                                store.remove(id: snippet.id)
                            }
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)

                        if index < store.snippets.count - 1 {
                            Divider()
                                .padding(.leading, 20)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()

                Button(
                    copy.restoreSnippetDefaults,
                    systemImage: "arrow.counterclockwise"
                ) {
                    store.restoreDefaults()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: SnippetTableColumns.spacing) {
            Text(copy.snippetColumnName)
                .frame(
                    width: SnippetTableColumns.nameWidth,
                    alignment: .leading
                )
            Text(copy.snippetColumnTrigger)
                .frame(
                    width: SnippetTableColumns.triggerWidth,
                    alignment: .leading
                )
            Text(copy.snippetColumnStatus)
                .frame(
                    width: SnippetTableColumns.statusWidth,
                    alignment: .leading
                )
            Text(copy.snippetColumnContent)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Color 会占满一切可用高度，必须固定高度，否则表头会撑开并挤压列表。
            Color.clear
                .frame(width: SnippetTableColumns.actionsWidth, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }
}

private enum SnippetTableColumns {
    static let spacing: CGFloat = 12
    static let nameWidth: CGFloat = 190
    static let triggerWidth: CGFloat = 110
    static let statusWidth: CGFloat = 110
    static let actionsWidth: CGFloat = 56
}

private struct SnippetTableRow: View {
    let snippet: SQLSnippet
    let copy: SettingsCopy
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: SnippetTableColumns.spacing) {
            Text(snippet.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(
                    width: SnippetTableColumns.nameWidth,
                    alignment: .leading
                )

            Text(snippet.trigger)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                )
                .frame(
                    width: SnippetTableColumns.triggerWidth,
                    alignment: .leading
                )

            HStack(spacing: 6) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { snippet.isEnabled },
                        set: { onToggle($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(
                    snippet.isEnabled
                        ? copy.snippetEnabled : copy.snippetDisabled
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(
                width: SnippetTableColumns.statusWidth,
                alignment: .leading
            )

            Text(SQLSnippetTemplate(content: snippet.content).previewText)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .help(copy.editSnippet)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help(copy.delete)
            }
            .buttonStyle(.borderless)
            .frame(
                width: SnippetTableColumns.actionsWidth,
                alignment: .trailing
            )
        }
    }
}

private struct SnippetEditorContext: Identifiable {
    let id = UUID()
    let snippet: SQLSnippet?
}

private struct SnippetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: SQLSnippetStore
    let snippet: SQLSnippet?

    @State private var name: String
    @State private var trigger: String
    @State private var content: String
    @State private var isEnabled: Bool
    @State private var showsValidation = false

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    init(store: SQLSnippetStore, snippet: SQLSnippet?) {
        self.store = store
        self.snippet = snippet
        _name = State(initialValue: snippet?.name ?? "")
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _content = State(initialValue: snippet?.content ?? "")
        _isEnabled = State(initialValue: snippet?.isEnabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(snippet == nil ? copy.newSnippet : copy.editSnippet)
                .font(.headline)

            field(title: copy.snippetNameField, validation: nameValidation) {
                TextField(copy.snippetNameField, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            field(title: copy.snippetTriggerField, validation: triggerValidation) {
                TextField(copy.snippetTriggerField, text: $trigger)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 160)
            }

            Toggle(copy.snippetEnabledField, isOn: $isEnabled)

            VStack(alignment: .leading, spacing: 6) {
                Text(copy.snippetContentField)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 170)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                contentValidation == nil
                                    ? Color(nsColor: .separatorColor)
                                    : .red,
                                lineWidth: 1
                            )
                    )

                if let contentValidation {
                    Text(contentValidation)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Text(copy.snippetPlaceholderHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()

                Button(copy.cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(copy.save) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func field(
        title: String,
        validation: String?,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)

            content()

            if let validation {
                Text(validation)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTrigger: String {
        trigger.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var nameValidation: String? {
        guard trimmedName.isEmpty else { return nil }
        return showsValidation ? copy.snippetValidationNameRequired : nil
    }

    private var triggerValidation: String? {
        switch store.triggerIssue(trimmedTrigger, excluding: snippet?.id) {
        case .required: showsValidation ? copy.snippetValidationTriggerRequired : nil
        case .whitespace: copy.snippetValidationTriggerInvalid
        case .duplicate: copy.snippetValidationTriggerDuplicate
        case nil: nil
        }
    }

    private var contentValidation: String? {
        guard content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return showsValidation ? copy.snippetValidationContentRequired : nil
    }

    private func save() {
        guard nameValidation == nil,
            triggerValidation == nil,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showsValidation = true
            return
        }
        if var existing = snippet {
            existing.name = trimmedName
            existing.trigger = trimmedTrigger
            existing.content = content
            existing.isEnabled = isEnabled
            store.update(existing)
        } else {
            store.add(
                SQLSnippet(
                    name: trimmedName,
                    trigger: trimmedTrigger,
                    content: content,
                    isEnabled: isEnabled
                )
            )
        }
        dismiss()
    }
}
