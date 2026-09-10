import SwiftUI

struct WorkspaceElasticsearchRequestDocumentView: View {
    @Bindable var document: WorkspaceElasticsearchRequestDocumentModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                WorkspaceCodeEditElasticsearchEditor(
                    text: $document.source,
                    selectedRange: $document.selectedRange,
                    navigationRequest: document.navigationRequest,
                    completionFields: { resourceName in
                        await document.completionFieldNames(
                            for: resourceName
                        )
                    },
                    completionResources: {
                        document.completionResourceNames()
                    }
                )
                actionBar
            }
            .frame(minHeight: 220, idealHeight: 430)

            resultArea
                .frame(minHeight: 220, idealHeight: 320)
        }
        .alert(
            AppCopy.current.text("请求无效", "Invalid Request"),
            isPresented: errorPresentation
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(document.editorErrorMessage ?? "")
        }
        .onDisappear { document.stop() }
        .alert(AppCopy.current.text("确认执行写请求", "Confirm Write Requests"), isPresented: Binding(
            get: { document.pendingConfirmation != nil },
            set: { if !$0 { document.cancelConfirmation() } }
        )) {
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) { document.cancelConfirmation() }
            Button(AppCopy.current.text("执行", "Run"), role: .destructive) { document.confirmExecution() }
        } message: {
            Text((document.pendingConfirmation ?? []).map { "\($0.request.method.rawValue) \($0.request.path)" }.joined(separator: "\n"))
        }
        .focusedSceneValue(
            \.workspaceQueryCommandActions,
            commandActions
        )
        .accessibilityIdentifier("elasticsearchRequestDocument.\(document.id)")
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            Button(
                document.isExecuting
                    ? AppCopy.current.text("停止", "Stop")
                    : AppCopy.current.text("运行当前请求", "Run Current"),
                systemImage: document.isExecuting ? "stop.fill" : "play.fill",
                action: runOrStop
            )
            .keyboardShortcut(.return, modifiers: .command)

            Button(
                AppCopy.current.text("运行全部", "Run All"),
                systemImage: "play.rectangle.on.rectangle",
                action: document.runAll
            )
            .disabled(document.isExecuting)

            Button(
                AppCopy.current.text("格式化", "Format"),
                systemImage: "text.alignleft",
                action: document.format
            )
            .disabled(document.isExecuting)

            Button(
                document.isSaving
                    ? AppCopy.current.text("正在保存", "Saving")
                    : AppCopy.current.text("保存", "Save"),
                systemImage: "square.and.arrow.down",
                action: document.requestSave
            )
            .disabled(!document.canSave)

            WorkspaceQueryRowLimitMenuControl(
                selection: $document.resultRowLimit,
                width: 128,
                isEnabled: !document.isExecuting
            )
            .frame(width: 128)

            Spacer()
        }
        .controlSize(.regular)
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var resultArea: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            if document.results.isEmpty {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    WorkspaceDatabaseDataProgressBar(
                        isActive: document.isExecuting,
                        accessibilityLabel: AppCopy.current.text(
                            "正在运行请求",
                            "Running Request"
                        )
                    )
                }
            } else {
                VStack(spacing: 0) {
                    if document.results.count > 1 {
                        Picker(
                            AppCopy.current.text("响应", "Response"),
                            selection: $document.selectedResultIndex
                        ) {
                            ForEach(document.results.indices, id: \.self) { index in
                                Text(AppCopy.current.text(
                                    "响应 \(index + 1)",
                                    "Response \(index + 1)"
                                )).tag(index)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(8)
                    }
                    if document.results.indices.contains(
                        document.selectedResultIndex
                    ) {
                        let result = document.results[document.selectedResultIndex]
                        WorkspaceElasticsearchConsoleResultView(
                            result: result,
                            canLocateError: document.canLocateError(in: result),
                            locateError: { document.locateError(in: result) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { document.editorErrorMessage != nil },
            set: { isPresented in
                if !isPresented { document.dismissEditorError() }
            }
        )
    }

    private func runOrStop() {
        if document.isExecuting {
            document.stop()
        } else {
            document.runCurrent()
        }
    }

    private var commandActions: WorkspaceQueryCommandActions {
        WorkspaceQueryCommandActions(
            selectionOrCurrentStatementAvailability: .available,
            runAllAvailability: .available,
            isRunning: document.isExecuting,
            transactionState: .autoCommit,
            requiresSessionDisconnect: false,
            canSave: document.canSave,
            save: document.requestSave,
            runSelectionOrCurrentStatement: document.runCurrent,
            runAll: document.runAll,
            stop: document.stop,
            commitTransaction: {},
            rollbackTransaction: {},
            formatSelectionOrCurrentStatement: document.format,
            formatDocument: document.format
        )
    }
}
