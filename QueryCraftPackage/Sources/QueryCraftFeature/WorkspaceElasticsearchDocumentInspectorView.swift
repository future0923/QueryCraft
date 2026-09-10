import SwiftUI

struct WorkspaceElasticsearchDocumentInspectorView: View {
    let context: WorkspaceElasticsearchDocumentInspectorContext
    let searchText: String

    @ViewBuilder
    var body: some View {
        if context.model.editingState == .creating {
            WorkspaceElasticsearchDocumentCreationView(context: context)
        } else {
            loadedDocumentContent
        }
    }

    @ViewBuilder
    private var loadedDocumentContent: some View {
        switch context.model.state {
        case .empty:
            ContentUnavailableView(
                AppCopy.current.text("未选择文档", "No Document Selected"),
                systemImage: "doc.text.magnifyingglass",
                description: Text(
                    AppCopy.current.text(
                        "选择一行以查看原始文档。",
                        "Select one row to inspect the source document."
                    )
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loading:
            VStack(spacing: 0) {
                Color(nsColor: .windowBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                WorkspaceDatabaseDataProgressBar(
                    isActive: true,
                    accessibilityLabel: AppCopy.current.text(
                        "正在加载文档",
                        "Loading Document"
                    )
                )
            }

        case .failed(_, let message):
            ContentUnavailableView {
                Label(
                    AppCopy.current.text("无法加载文档", "Unable to Load Document"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            }

        case .loaded(let snapshot):
            document(context.model.cellChanges.entries[snapshot.reference]?.snapshot ?? snapshot)
        }
    }

    private func document(_ snapshot: WorkspaceDocumentSnapshot) -> some View {
        let source = context.model.cellChanges.entries[snapshot.reference]?.sourceText
            ?? String(data: snapshot.sourceJSON, encoding: .utf8) ?? ""
        let normalizedSearch = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let metadataFields = metadata(snapshot).filter {
            normalizedSearch.isEmpty
                || $0.name.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.type.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.value.localizedCaseInsensitiveContains(normalizedSearch)
        }
        let sourceMatches = normalizedSearch.isEmpty
            || "_source".localizedCaseInsensitiveContains(normalizedSearch)
            || "json".localizedCaseInsensitiveContains(normalizedSearch)
            || source.localizedCaseInsensitiveContains(normalizedSearch)
        let fieldCount = metadataFields.count + (sourceMatches ? 1 : 0)

        return VStack(spacing: 0) {
            HStack {
                Text(AppCopy.current.text("文档字段", "Document Fields"))
                Spacer()
                Text("\(fieldCount)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)

            Divider()

            ForEach(metadataFields, id: \.name) { field in
                metadataField(field)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            if sourceMatches {
                WorkspaceElasticsearchDocumentSourceField(
                    context: context,
                    source: source
                )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, snapshot.isTruncated ? 4 : 10)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
            }

            if sourceMatches && snapshot.isTruncated {
                Label(
                    AppCopy.current.text(
                        "文档超过显示上限，内容已截断。",
                        "The document exceeds the display limit and was truncated."
                    ),
                    systemImage: "scissors"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if fieldCount == 0 && !normalizedSearch.isEmpty {
                Text(
                    AppCopy.current.text(
                        "没有匹配的字段",
                        "No matching fields"
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func metadata(
        _ snapshot: WorkspaceDocumentSnapshot
    ) -> [(name: String, type: String, value: String)] {
        var fields: [(name: String, type: String, value: String)] = [
            ("_id", "keyword", snapshot.reference.id),
            ("_index", "keyword", snapshot.reference.index),
            ("_version", "long", snapshot.version.map(String.init) ?? "-"),
            ("_seq_no", "long", snapshot.sequenceNumber.map(String.init) ?? "-"),
            ("_primary_term", "long", snapshot.primaryTerm.map(String.init) ?? "-"),
            ("_score", "double", snapshot.score.map { String($0) } ?? "-"),
        ]
        if let routing = snapshot.reference.routing {
            fields.append(("_routing", "keyword", routing))
        }
        return fields
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

    private func fieldHeader(name: String, type: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.subheadline)
                .lineLimit(1)
                .help(name)

            Spacer(minLength: 8)

            Text(type)
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

private struct WorkspaceElasticsearchDocumentCreationView: View {
    let context: WorkspaceElasticsearchDocumentInspectorContext

    var body: some View {
        @Bindable var model = context.model

        VStack(spacing: 0) {
            HStack {
                Text(AppCopy.current.text("新增文档", "New Document"))
                Spacer()
                Text(model.creationTargetName ?? context.selection.objectName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.creationTargetName ?? context.selection.objectName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                identityField(
                    name: "_id",
                    placeholder: AppCopy.current.text(
                        "留空则自动生成",
                        "Leave empty to generate automatically"
                    ),
                    text: $model.creationDocumentID
                )

                identityField(
                    name: "_routing",
                    placeholder: AppCopy.current.text("可选", "Optional"),
                    text: $model.creationRouting
                )

                HStack(spacing: 6) {
                    Text("_source")
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    Text("json")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }

                WorkspaceCodeEditJSONEditor(text: $model.draftText)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 120,
                        maxHeight: .infinity
                    )

                validationStatus(model)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: model.creationDocumentID) { _, _ in
            updateDraft(model)
        }
        .onChange(of: model.creationRouting) { _, _ in
            updateDraft(model)
        }
        .onChange(of: model.draftText) { _, _ in
            updateDraft(model)
        }
        .accessibilityIdentifier("elasticsearchDocumentCreationEditor")
        .disabled(context.isReadOnly || model.isCommitting)
    }

    private func identityField(
        name: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name)
                    .font(.subheadline)
                Spacer()
                Text("keyword")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(name)
        }
    }

    @ViewBuilder
    private func validationStatus(
        _ model: WorkspaceElasticsearchDocumentInspectorModel
    ) -> some View {
        if let message = model.validationErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if model.isValidating {
            Text(AppCopy.current.text("正在检查 JSON…", "Validating JSON..."))
                .foregroundStyle(.secondary)
        } else if model.preparedCreation != nil {
            Text(AppCopy.current.text("有待提交更改", "Changes pending"))
                .foregroundStyle(.secondary)
        } else {
            Text(" ")
                .accessibilityHidden(true)
        }
    }

    private func updateDraft(
        _ model: WorkspaceElasticsearchDocumentInspectorModel
    ) {
        context.updateCreationDraft(
            model.creationDocumentID,
            model.creationRouting,
            model.draftText
        )
    }
}
