import SwiftUI

struct MobileConnectionList: View {
    @Bindable var app: MobileApplicationModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        List {
            ForEach(app.library.profiles) { profile in
                Button { app.open(profile) } label: { MobileConnectionRow(profile: profile) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("编辑", systemImage: "pencil") { app.edit(profile) }
                        Button("删除连接", systemImage: "trash", role: .destructive) { app.pendingDeletion = profile }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除") { app.pendingDeletion = profile }.tint(.red)
                        Button("编辑") { app.edit(profile) }.tint(.blue)
                    }
            }
            if let message = app.message {
                Section { Text(message).font(.footnote).foregroundStyle(.red) }
            }
        }
        .listStyle(.insetGrouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("connectionHome")
        .overlay {
            if app.libraryLoaded, app.library.profiles.isEmpty, app.message == nil {
                ContentUnavailableView {
                    Label("添加第一个连接", systemImage: "externaldrive.connected.to.line.below")
                } description: {
                    Text("保存数据库连接，随时开始查询。")
                } actions: {
                    Button("添加连接") { app.edit(nil) }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .navigationTitle("连接")
        .navigationBarTitleDisplayMode(sizeClass == .regular ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("数据迁移", systemImage: "arrow.left.arrow.right") { app.openTransfer() } }
            if !app.library.profiles.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("添加连接", systemImage: "plus") { app.edit(nil) }
                        .disabled(!app.libraryLoaded).accessibilityIdentifier("addConnection")
                }
            }
            if !app.libraryLoaded {
                ToolbarItem(placement: .primaryAction) {
                    Button("重新加载连接", systemImage: "arrow.clockwise", action: app.reloadLibrary)
                }
            }
        }
    }
}

private struct MobileConnectionRow: View {
    let profile: MobileConnectionProfile
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive")
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.08), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(profile.driver.title + " · " + profile.host + ":" + String(profile.port))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开连接")
    }
}
