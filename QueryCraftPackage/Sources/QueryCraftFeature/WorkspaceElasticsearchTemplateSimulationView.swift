import SwiftUI

struct WorkspaceElasticsearchTemplateSimulationView: View {
    let execute: @MainActor (WorkspaceRequest) async throws -> WorkspaceRequestExecutionResult
    @State private var model = WorkspaceElasticsearchTemplateSimulationModel()
    @State private var indexName = ""
    @State private var submission: Submission?
    @State private var section = Section.settings

    private struct Submission: Equatable {
        let id = UUID()
        let name: String
    }

    private enum Section: String, CaseIterable {
        case settings = "Settings", mappings = "Mapping", aliases = "Aliases", response
        var title: String {
            self == .response ? AppCopy.current.text("完整响应", "Full Response") : rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppCopy.current.text("模板匹配预览", "Template Match Preview")).font(.headline)
                HStack {
                    TextField(AppCopy.current.text("准备创建的索引名称", "Index name to create"), text: $indexName)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("templateSimulationIndexName")
                        .onSubmit(start)
                    Button(AppCopy.current.text("预览匹配", "Preview Match"), action: start)
                        .disabled(indexName.isEmpty)
                        .accessibilityIdentifier("templateSimulationRun")
                    WorkspaceInlineIconButton(systemImageName: "stop.fill",
                        title: AppCopy.current.text("停止预览", "Stop Preview"), isEnabled: model.isLoading,
                        action: stop)
                }
                Text(AppCopy.current.text(
                    "按服务器已保存的可组合索引模板预览，不包含未保存草稿，也不会创建索引。",
                    "Preview saved composable index templates. Unsaved drafts are excluded; no index is created."))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = model.error {
                        Text(error).foregroundStyle(.red)
                    }
                    if let result = model.result {
                        Text(AppCopy.current.text("结果对应索引：\(result.indexName)", "Result for index: \(result.indexName)"))
                        if result.error == nil {
                            Text(result.hasTemplate
                                ? AppCopy.current.text("匹配模板（优先级从高到低）：\(result.matchedTemplates.joined(separator: "、"))",
                                    "Matching templates (highest priority first): \(result.matchedTemplates.joined(separator: ", "))")
                                : AppCopy.current.text("未匹配可组合索引模板；此处不展示旧式模板或完整索引默认值。",
                                    "No composable index template matched. Legacy templates and full index defaults are not shown."))
                            if result.hasTemplate {
                                Text(AppCopy.current.text(
                                    "最高优先级模板生效，低优先级模板不会叠加。模板列表与模拟结果分别读取，最终配置以服务器结果为准。",
                                    "The highest-priority template applies; lower-priority templates are not merged. The catalog and simulation are read separately; settings below come from the server."))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if model.error == nil {
                        Text(AppCopy.current.text("输入索引名称后点击“预览匹配”。", "Enter an index name and click Preview Match."))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .font(.callout)
            .frame(height: 66)
            .padding(10)
            Picker(AppCopy.current.text("预览内容", "Preview Content"), selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            WorkspaceJSONTextView(text: .constant(displayedJSON),
                accessibilityLabel: AppCopy.current.text("模板匹配结果 JSON", "Template Match Result JSON"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            WorkspaceDatabaseDataProgressBar(isActive: model.isLoading,
                accessibilityLabel: AppCopy.current.text("正在预览模板匹配", "Previewing Template Match"))
        }
        .task(id: submission) {
            if let submission { await model.load(indexName: submission.name, execute: execute) }
        }
        .onChange(of: indexName) { _, _ in stop() }
        .onChange(of: model.error) { _, error in if error != nil { section = .response } }
        .onDisappear { model.cancel() }
    }

    private var displayedJSON: String {
        guard let result = model.result else { return "{}" }
        switch section {
        case .settings: return result.settings
        case .mappings: return result.mappings
        case .aliases: return result.aliases
        case .response: return result.response
        }
    }

    private func start() {
        guard !indexName.isEmpty else { return }
        model.cancel()
        submission = Submission(name: indexName)
    }

    private func stop() {
        submission = nil
        model.cancel()
    }
}
