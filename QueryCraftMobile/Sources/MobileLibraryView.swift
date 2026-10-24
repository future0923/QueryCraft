import SwiftUI

struct MobileLibraryView: View {
    @Bindable var app: MobileApplicationModel
    var body: some View {
        Group {
            if app.isWorkspacePresented, let resource = app.resourceWorkspace {
                MobileResourceWorkspaceView(app: app, model: resource).id(resource.profile.id)
            } else if app.isWorkspacePresented, let workspace = app.workspace {
                MobileConnectionWorkspaceView(app: app, workspace: workspace).id(workspace.id)
            } else {
                NavigationStack { MobileConnectionList(app: app) }
            }
        }
        .sheet(item: $app.editingConnection) { draft in MobileConnectionForm(draft: draft) { try app.save(draft) } }
        .sheet(item: $app.passwordPrompt) { profile in
            MobilePasswordPrompt(profile: profile) { password in app.open(profile, suppliedPassword: password) }
        }
        .confirmationDialog("删除连接及其查询历史？", isPresented: Binding(get: { app.pendingDeletion != nil }, set: { if !$0 { app.pendingDeletion = nil } }), titleVisibility: .visible) {
            Button("删除连接", role: .destructive) {
                if let profile = app.pendingDeletion { do { try app.delete(profile) } catch { app.message = error.localizedDescription } }
            }
        }
    }
}

private struct MobilePasswordPrompt: View {
    let profile: MobileConnectionProfile
    let connect: (String) -> Void
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text(profile.name)
                SecureField("连接密码", text: $password).textContentType(.password)
                Text("本次输入仅保留在当前进程中。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("输入密码").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("连接") { connect(password) } }
                }
        }
    }
}
