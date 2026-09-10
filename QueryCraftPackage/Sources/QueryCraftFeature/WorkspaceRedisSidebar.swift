import AppKit
import SwiftUI

struct WorkspaceRedisSidebar: View {
    @Bindable var model: WorkspaceModel
    let openKey: @MainActor (RedisKeyReference) -> Void
    let renameKey: @MainActor (RedisKeyReference) -> Void

    @State private var isShowingLoadAllConfirmation = false
    @State private var keyPendingDelete: RedisKeyReference?
    @State private var keyPendingDeleteAfterUnlock: RedisKeyReference?
    @State private var keyDeletionErrorMessage: String?
    @State private var keyDeletionTask: Task<Void, Never>?
    @State private var preferences = ApplicationPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            if model.connectionState == .connected {
                keyList
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .top
                    )
            } else {
                connectionState
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .top
                    )
            }
            WorkspaceDatabaseDataProgressBar(
                isActive: model.isLoadingRedisKeys,
                accessibilityLabel: AppCopy.current.text(
                    "正在扫描 Key",
                    "Scanning keys"
                )
            )
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear(perform: model.stopRedisKeyLoading)
        .alert(
            AppCopy.current.text("加载全部 Key？", "Load All Keys?"),
            isPresented: $isShowingLoadAllConfirmation
        ) {
            Button(AppCopy.current.text("加载全部", "Load All")) {
                model.startRedisKeyLoad(
                    reset: false,
                    scope: .allRemaining
                )
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(loadAllConfirmationMessage)
        }
        .alert(
            AppCopy.current.text("删除 Key？", "Delete Key?"),
            isPresented: deleteConfirmationPresentation,
            presenting: keyPendingDelete
        ) { reference in
            Button(
                AppCopy.current.text("删除", "Delete"),
                role: .destructive
            ) {
                requestDeleteKey(reference)
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: { reference in
            Text(
                AppCopy.current.text(
                    "将永久删除 Key“\(reference.name)”，并关闭对应标签页。此操作无法撤销。",
                    "This permanently deletes the “\(reference.name)” key and closes its tab. This action cannot be undone."
                )
            )
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: deleteSafetyLockPresentation
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                guard let reference = keyPendingDeleteAfterUnlock else {
                    return
                }
                keyPendingDeleteAfterUnlock = nil
                model.safetyLock.disable()
                deleteKey(reference)
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                keyPendingDeleteAfterUnlock = nil
            }
        } message: {
            Text(
                AppCopy.current.text(
                    "删除 Key 会永久移除其数据。安全锁将保持停用，直到此工作区关闭。",
                    "Deleting a key permanently removes its data. Safety Lock will remain disabled until this workspace closes."
                )
            )
        }
        .alert(
            AppCopy.current.text("无法删除 Key", "Unable to Delete Key"),
            isPresented: deletionErrorPresentation
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(keyDeletionErrorMessage ?? "")
        }
        .onDisappear {
            keyDeletionTask?.cancel()
            keyDeletionTask = nil
        }
    }

    @ViewBuilder
    private var keyList: some View {
        if let message = model.redisKeyLoadErrorMessage,
                  model.redisKeys.isEmpty
        {
            ContentUnavailableView {
                Label(
                    AppCopy.current.text("无法加载 Key", "Unable to Load Keys"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            } actions: {
                Button(AppCopy.current.text("重试", "Retry")) {
                    model.startRedisKeyPageLoad(reset: true)
                }
            }
        } else if model.redisKeyTree.isEmpty && !model.isLoadingRedisKeys {
            ContentUnavailableView(
                model.activeRedisKeySearchText.isEmpty
                    ? AppCopy.current.text("没有 Key", "No Keys")
                    : AppCopy.current.text("没有匹配的 Key", "No Matching Keys"),
                systemImage: "key",
                description: Text(
                    model.activeRedisKeySearchText.isEmpty
                        ? AppCopy.current.text(
                            "当前逻辑数据库为空。",
                            "This logical database is empty."
                        )
                        : AppCopy.current.text(
                            model.isRedisKeyScanComplete
                                ? "Redis 中没有匹配的 Key。"
                                : "当前扫描批次没有匹配项，可继续加载。",
                            model.isRedisKeyScanComplete
                                ? "No matching keys were found in Redis."
                                : "This scan batch has no matches; continue loading."
                        )
                )
            )
        } else {
            WorkspaceRedisKeyOutlineView(
                nodes: model.redisKeyTree,
                revision: model.redisKeyTreeRevision,
                expandsAllItems: !model.activeRedisKeySearchText.isEmpty,
                selection: sidebarSelection,
                openKey: openKey,
                renameKey: renameKey,
                copyKeyName: copyKeyName,
                deleteKey: { keyPendingDelete = $0 },
                automaticallyResolvesKeyTypes: preferences
                    .automaticallyResolvesVisibleRedisKeyTypes,
                typeResolutionBatchSize: preferences
                    .redisVisibleKeyTypeBatchSize,
                resolveKeyTypes: resolveVisibleKeyTypes
            )
        }
    }

    @ViewBuilder
    private var connectionState: some View {
        switch model.connectionState {
        case .connecting:
            ProgressView(AppCopy.current.text("正在连接…", "Connecting..."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView(
                AppCopy.current.text("连接已断开", "Disconnected"),
                systemImage: "exclamationmark.triangle"
            )
        case .connected:
            EmptyView()
        }
    }

    private var footer: some View {
        WorkspaceRedisSidebarFooter(
            model: model,
            loadAll: requestLoadAll
        )
    }

    private var sidebarSelection: Binding<RedisKeyReference?> {
        Binding(
            get: { model.redisSidebarSelection },
            set: { reference in
                guard let reference else {
                    model.redisSidebarSelection = nil
                    return
                }
                openKey(reference)
            }
        )
    }

    private var deleteConfirmationPresentation: Binding<Bool> {
        Binding(
            get: { keyPendingDelete != nil },
            set: { if !$0 { keyPendingDelete = nil } }
        )
    }

    private var deleteSafetyLockPresentation: Binding<Bool> {
        Binding(
            get: { keyPendingDeleteAfterUnlock != nil },
            set: { if !$0 { keyPendingDeleteAfterUnlock = nil } }
        )
    }

    private var deletionErrorPresentation: Binding<Bool> {
        Binding(
            get: { keyDeletionErrorMessage != nil },
            set: { if !$0 { keyDeletionErrorMessage = nil } }
        )
    }

    private func copyKeyName(_ reference: RedisKeyReference) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference.name, forType: .string)
    }

    private func resolveVisibleKeyTypes(_ references: [RedisKeyReference]) {
        Task { @MainActor in
            _ = try? await model.resolveRedisKeyTypes(references)
        }
    }

    private func requestDeleteKey(_ reference: RedisKeyReference) {
        if model.safetyLock.isEnabled {
            keyPendingDeleteAfterUnlock = reference
        } else {
            deleteKey(reference)
        }
    }

    private func deleteKey(_ reference: RedisKeyReference) {
        guard keyDeletionTask == nil else { return }
        keyDeletionTask = Task { @MainActor in
            defer { keyDeletionTask = nil }
            do {
                try await model.deleteRedisKey(reference)
            } catch is CancellationError {
                return
            } catch {
                keyDeletionErrorMessage = error.localizedDescription
            }
        }
    }

    private func requestLoadAll() {
        let total = model.currentRedisDatabaseReportedKeyCount
        if total == nil || total ?? 0 >= Self.largeDatabaseKeyCount {
            isShowingLoadAllConfirmation = true
        } else {
            model.startRedisKeyLoad(reset: false, scope: .allRemaining)
        }
    }

    private var loadAllConfirmationMessage: String {
        if let total = model.currentRedisDatabaseReportedKeyCount {
            return AppCopy.current.text(
                "将使用 SCAN 遍历约 \(total) 个 Key。操作可停止，但会增加 Redis 和本机内存负载。",
                "SCAN will traverse about \(total) keys. You can stop it, but it increases Redis and local memory load."
            )
        }
        return AppCopy.current.text(
            "将使用 SCAN 遍历当前数据库的全部 Key。操作可停止，但会增加 Redis 和本机内存负载。",
            "SCAN will traverse every key in the current database. You can stop it, but it increases Redis and local memory load."
        )
    }

    private static let largeDatabaseKeyCount = 50_000
}
