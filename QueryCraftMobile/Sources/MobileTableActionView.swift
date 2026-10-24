import SwiftUI
import UIKit

struct MobileTableActionMenu: View {
    let controller: MobileTableActionController
    let object: MobileDatabaseObject
    var body: some View {
        if controller.onImport != nil { Button("导入数据…", systemImage: "square.and.arrow.down") { controller.onImport?(object) }.disabled(controller.blocksWrites) }
        ForEach(WorkspaceTableAction.allCases) { action in
            Button(action.title, role: action.isDestructive ? .destructive : nil) { controller.prepare(action, object: object) }
                .disabled(controller.isSubmitting)
                .accessibilityIdentifier("tableAction.\(action.rawValue)")
        }
    }
}

struct MobileTableActionView: View {
    @Bindable var controller: MobileTableActionController
    @Bindable var draft: MobileTableActionDraft
    @State private var showsUnlock = false
    @State private var showsSQL = false
    private enum Input: Hashable { case value, confirmation }
    @FocusState private var focusedInput: Input?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("数据库", value: draft.object.database)
                    if let schema = draft.object.schemaName { LabeledContent("Schema", value: schema) }
                    LabeledContent("表", value: draft.object.name)
                } footer: { Text(draft.action.explanation(for: draft.databaseType)) }
                if draft.action == .rename || draft.action == .setAutoIncrement {
                    Section {
                        LabeledContent(draft.action == .rename ? "新表名" : "下一自增值") {
                            TextField(draft.action == .rename ? "请输入新表名" : "正整数", text: $draft.input)
                                .multilineTextAlignment(.trailing).focused($focusedInput, equals: .value).disabled(draft.hasCompleted || draft.needsVerification)
                                .keyboardType(draft.action == .rename ? .default : .numbersAndPunctuation)
                                .submitLabel(.done).accessibilityIdentifier("tableActionInput")
                        }
                    }
                }
                if draft.action == .setAutoIncrement || draft.action == .resetAutoIncrement {
                    Section {
                        HStack {
                            LabeledContent(draft.databaseType == .postgresql ? "所属 serial / identity 序列" : "当前下一自增值") {
                                Text(draft.databaseType == .postgresql ? (draft.info?.hasAutoIncrement == true ? "有（执行时重新解析）" : "—") : (draft.info?.nextAutoIncrement ?? "—")).font(.footnote.monospacedDigit()).lineLimit(1).textSelection(.enabled)
                            }
                            ProgressView().controlSize(.small).opacity(draft.isInspecting ? 1 : 0)
                        }
                    } footer: { Text(draft.info?.hasAutoIncrement == false ? "此表没有自增列" : " ").foregroundStyle(.red).frame(height: 20) }
                }
                if draft.action.isDestructive {
                    Section {
                        LabeledContent("确认表名") {
                            TextField(draft.object.name, text: $draft.confirmation).multilineTextAlignment(.trailing)
                                .focused($focusedInput, equals: .confirmation).submitLabel(.done).disabled(draft.hasCompleted || draft.needsVerification).accessibilityIdentifier("tableActionConfirmation")
                        }
                    } footer: { Text("输入完整表名以确认此次操作。") }
                }
                Section {
                    DisclosureGroup("SQL 预览", isExpanded: $showsSQL) {
                        Text(draft.statement.map { $0.sql + ";" } ?? "请输入有效参数")
                            .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        ProgressView().controlSize(.small).opacity(controller.isSubmitting ? 1 : 0)
                        Text(controller.isSubmitting ? "正在执行…" : (draft.message ?? (draft.hasCompleted ? "操作已完成" : "确认后才会执行")))
                            .font(.footnote).foregroundStyle(draft.message == nil ? Color.secondary : .red).lineLimit(3)
                    }.frame(height: 64)
                    if draft.needsVerification {
                        Text("关闭后使用顶部刷新核对服务器的表名、数据或自增值。此操作可能已完成，请勿重复执行。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("我已核对服务器，结束此操作") { controller.acknowledgeVerification(draft) }
                            .disabled(controller.isSubmitting)
                    } else {
                        Button(draft.action.title, role: draft.action.isDestructive ? .destructive : nil) {
                            dismissKeyboard()
                            if controller.safetyLock.isEnabled { showsUnlock = true }
                            else { controller.submit(draft) }
                        }.disabled(!draft.canSubmit || controller.isSubmitting)
                            .accessibilityIdentifier("tableActionSubmit")
                    }
                }
            }
            .disabled(controller.isSubmitting)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .onSubmit { dismissKeyboard() }
            .navigationTitle(draft.action.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(draft.hasCompleted ? "关闭" : "取消") { controller.dismiss() }.disabled(controller.isSubmitting)
            } }
            .interactiveDismissDisabled(controller.isSubmitting)
            .alert("停用安全锁？", isPresented: $showsUnlock) {
                Button("取消", role: .cancel) {}
                Button("解锁并执行", role: .destructive) { controller.safetyLock.disable(); controller.submit(draft) }
            } message: { Text("允许对 \(draft.object.database).\(draft.object.name) 执行已预览的操作。") }
            .task { await controller.inspect(draft)?.value }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_TABLE_SQL"] == "1" { showsSQL = true }
                #endif
            }
        }
    }
    private func dismissKeyboard() {
        focusedInput = nil
        // End the native responder synchronously too: Form submission can be
        // delivered before SwiftUI has published its focus binding.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

}
