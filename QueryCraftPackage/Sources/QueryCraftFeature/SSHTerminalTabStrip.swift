import SwiftUI

/// Same navigation surface and metrics as database content tabs. The shaped
/// backgrounds stay inside the track and never extend behind the titlebar.
struct SSHTerminalTabStrip: View {
    let sessions: [SSHTerminalSession]
    let selection: UUID?
    let select: (UUID) -> Void
    let close: (SSHTerminalSession) -> Void
    @State private var hovered: UUID?
    @Environment(\.controlActiveState) private var controlActiveState
    var body: some View {
        glassContainer {
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                tab(session, index: index)
                                    .frame(width: WorkspaceContentTabStripLayout.tabWidth(forTrack: geometry.size.width, count: sessions.count))
                                    .id(session.id)
                            }
                        }
                    }
                    .frame(height: WorkspaceContentTabStripLayout.tabHeight)
                    .workspaceTabTrackClipShape()
                    .padding(WorkspaceContentTabStripLayout.trackPadding)
                    .onChange(of: selection) { _, value in
                        if let value { reader.scrollTo(value, anchor: .center) }
                    }
                }
            }
            .frame(height: WorkspaceContentTabStripLayout.trackHeight)
            .workspaceTabTrackSurface()
        }
        .padding(.horizontal, WorkspaceContentTabStripLayout.stripInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .controlSize(.large)
        .onChange(of: controlActiveState) { _, state in if state == .inactive { hovered = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppCopy.current.text("终端标签页", "Terminal Tabs"))
        .accessibilityAddTraits(.isTabBar)
    }
    @ViewBuilder private func glassContainer(@ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 0) { content() } }
        else { content() }
    }
    private func tab(_ session: SSHTerminalSession, index: Int) -> some View {
        let selected = selection == session.id
        let isHovered = hovered == session.id
        return ZStack {
            if index > 0, !selected, selection != sessions[index - 1].id, !isHovered, hovered != sessions[index - 1].id {
                HStack {
                    Rectangle().fill(Color(nsColor: .separatorColor))
                        .frame(width: WorkspaceContentTabStripLayout.hairline, height: WorkspaceContentTabStripLayout.separatorHeight)
                    Spacer()
                }
            }
            ZStack {
                Button { select(session.id) } label: {
                    HStack(spacing: 6) {
                        Color.clear.frame(width: WorkspaceContentTabStripLayout.accessoryWidth)
                        Spacer(minLength: 0)
                        Circle().fill(session.state == .connected ? Color.green : Color.secondary).frame(width: 5, height: 5)
                        Text(session.profile.name).lineLimit(1).truncationMode(.tail)
                            .foregroundStyle(Color(nsColor: selected ? .labelColor : .secondaryLabelColor))
                        Spacer(minLength: 0)
                        Color.clear.frame(width: WorkspaceContentTabStripLayout.accessoryWidth)
                    }.padding(.horizontal, WorkspaceContentTabStripLayout.accessoryInset).contentShape(Rectangle())
                }.buttonStyle(.plain)
                HStack {
                    if selected || (isHovered && controlActiveState != .inactive) {
                        Button(AppCopy.current.text("关闭终端", "Close Terminal"), systemImage: "xmark") { close(session) }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: WorkspaceContentTabStripLayout.accessoryWidth, height: WorkspaceContentTabStripLayout.accessoryWidth)
                    }
                    Spacer()
                }.padding(.leading, WorkspaceContentTabStripLayout.accessoryInset)
            }
            .frame(height: WorkspaceContentTabStripLayout.tabHeight)
            .workspaceTabSurface(isSelected: selected, isHovered: isHovered, isWindowActive: controlActiveState != .inactive)
        }
        .onHover { hovered = $0 ? session.id : (hovered == session.id ? nil : hovered) }
        .help(session.profile.name + " · " + session.status)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.profile.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: AppCopy.current.text("关闭终端", "Close Terminal")) { close(session) }
        .contextMenu { Button(AppCopy.current.text("关闭终端", "Close Terminal")) { close(session) } }
    }
}
