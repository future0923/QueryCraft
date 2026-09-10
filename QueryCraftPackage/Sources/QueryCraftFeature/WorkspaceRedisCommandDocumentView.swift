import SwiftUI

struct WorkspaceRedisCommandDocumentView: View {
    @Bindable var document: WorkspaceRedisCommandDocumentModel
    @Bindable var workspace: WorkspaceModel

    @State private var isShowingSafetyLockAlert = false
    @State private var inputFocusRequest = 1

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(spacing: 0) {
                RedisCommandTranscriptView(
                    entries: document.transcriptEntries,
                    revision: document.transcriptRevision
                )
                Divider()
                RedisCommandPromptBar(
                    databaseIndex: workspace.currentRedisDatabaseIndex,
                    document: document,
                    focusRequest: inputFocusRequest,
                    submit: run
                )
            }

            if !document.completions.isEmpty {
                RedisCommandCompletionList(
                    entries: Array(document.completions.prefix(7)),
                    selectedIndex: document.selectedCandidateIndex,
                    accept: acceptCompletion
                )
                .frame(maxWidth: 460)
                .frame(height: completionListHeight)
                .padding(.leading, 62)
                .padding(.trailing, 12)
                .padding(.bottom, 48)
            } else if let command = document.activeCommand,
                      !document.commandLineSnapshot.isEditingCommandName
            {
                RedisCommandArgumentAssistancePanel(
                    entry: command,
                    argument: document.activeArgument,
                    suggestions: document.argumentSuggestions,
                    selectedIndex: document.selectedCandidateIndex,
                    accept: acceptArgumentSuggestion
                )
                .frame(maxWidth: 560)
                .frame(height: argumentAssistanceHeight)
                .padding(.leading, 62)
                .padding(.trailing, 12)
                .padding(.bottom, 48)
            }
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $isShowingSafetyLockAlert
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                workspace.safetyLock.disable()
                document.run(allowingChanges: true)
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                requestInputFocus()
            }
        } message: {
            Text(
                AppCopy.current.text(
                    "此命令可能修改 Redis 数据。安全锁将保持停用，直到此工作区关闭。",
                    "This command may modify Redis data. Safety Lock remains disabled until this workspace closes."
                )
            )
        }
        .onChange(of: document.executionRevision) {
            requestInputFocus()
        }
        .onChange(of: workspace.currentRedisDatabaseIndex) {
            document.refreshSuggestionLoading()
        }
        .onAppear {
            document.refreshSuggestionLoading()
        }
        .onDisappear { document.stop() }
        .accessibilityIdentifier("redisCommandDocument.\(document.id)")
    }

    private var completionListHeight: Double {
        min(Double(document.completions.prefix(7).count) * 38 + 6, 196)
    }

    private var argumentAssistanceHeight: Double {
        let suggestionHeight = Double(document.argumentSuggestions.count) * 34
        return min(62 + suggestionHeight, 268)
    }

    private func run() {
        if document.requiresSafetyLockDisable && workspace.safetyLock.isEnabled {
            isShowingSafetyLockAlert = true
        } else {
            document.run()
        }
    }

    private func acceptCompletion(_ entry: RedisCommandCatalogEntry) {
        document.acceptCompletion(entry)
        requestInputFocus()
    }

    private func acceptArgumentSuggestion(
        _ suggestion: RedisCommandArgumentSuggestion
    ) {
        document.acceptArgumentSuggestion(suggestion)
        requestInputFocus()
    }

    private func requestInputFocus() {
        inputFocusRequest &+= 1
    }
}
