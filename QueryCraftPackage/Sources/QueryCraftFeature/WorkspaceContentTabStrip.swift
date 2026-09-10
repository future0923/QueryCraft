import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceContentTabStrip: View {
    @Bindable var tabsModel: WorkspaceContentTabsModel
    let selectContent: @MainActor (WorkspaceContentTabID) -> Void
    let performAction: @MainActor (WorkspaceContentTabAction) -> Void

    @State private var hoveredID: WorkspaceContentTabID?
    @State private var draggingID: WorkspaceContentTabID?
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        glassContainer {
            track
        }
        .padding(.horizontal, WorkspaceContentTabStripLayout.stripInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .controlSize(.large)
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { hoveredID = nil }
        }
        .onChange(of: tabsModel.contentItems.map(\.id)) { _, ids in
            if let hoveredID, !ids.contains(hoveredID) { self.hoveredID = nil }
            if let draggingID, !ids.contains(draggingID) { self.draggingID = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppCopy.current.text("内容标签页", "Content Tabs"))
        .accessibilityAddTraits(.isTabBar)
    }

    @ViewBuilder
    private func glassContainer(@ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { content() }
        } else {
            content()
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    if #available(macOS 26.0, *) {
                        HStack(spacing: 0) {
                            ForEach(
                                Array(tabsModel.contentItems.enumerated()),
                                id: \.element.id
                            ) { index, item in
                                tab(item, at: index)
                                    .frame(
                                        width: WorkspaceContentTabStripLayout.tabWidth(
                                            forTrack: proxy.size.width,
                                            count: tabsModel.contentItems.count
                                        )
                                    )
                                    .id(item.id)
                            }
                        }
                    } else {
                        WorkspaceLegacyContentTabLayout(
                            availableWidth: proxy.size.width
                        ) {
                            ForEach(
                                Array(tabsModel.contentItems.enumerated()),
                                id: \.element.id
                            ) { index, item in
                                tab(item, at: index)
                                    .id(item.id)
                            }
                        }
                    }
                }
                .onChange(of: tabsModel.selectedContentID) { _, selectedID in
                    guard let selectedID else { return }
                    if reduceMotion {
                        scroller.scrollTo(selectedID, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            scroller.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
            }
            .frame(height: WorkspaceContentTabStripLayout.tabHeight)
            .workspaceTabTrackClipShape()
            .padding(WorkspaceContentTabStripLayout.trackPadding)
        }
        .frame(height: WorkspaceContentTabStripLayout.trackHeight)
        .workspaceTabTrackSurface()
        .onDrop(
            of: [.text],
            delegate: WorkspaceContentTabDropReset(draggingID: $draggingID)
        )
    }

    private func tab(
        _ item: WorkspaceContentTabItem,
        at index: Int
    ) -> some View {
        WorkspaceContentTabStripItem(
            item: item,
            isSelected: tabsModel.selectedContentID == item.id,
            isHovered: hoveredID == item.id,
            isWindowActive: controlActiveState != .inactive,
            showsLeadingSeparator: WorkspaceContentTabStripLayout.showsSeparator(
                before: index,
                ids: tabsModel.contentItems.map(\.id),
                selectedID: tabsModel.selectedContentID,
                hoveredID: hoveredID,
                isReordering: draggingID != nil
            ),
            position: index + 1,
            count: tabsModel.contentItems.count,
            select: { selectContent(item.id) },
            close: { performAction(.close(item.id)) },
            closeOthers: { performAction(.closeOthers(item.id)) },
            closeToRight: { performAction(.closeToRight(item.id)) },
            closeAll: { performAction(.closeAll) },
            canMoveLeft: tabsModel.canMove(item.id, by: -1),
            canMoveRight: tabsModel.canMove(item.id, by: 1),
            moveLeft: { tabsModel.move(item.id, by: -1) },
            moveRight: { tabsModel.move(item.id, by: 1) }
        )
        .opacity(
            draggingID == item.id
                ? WorkspaceContentTabStripLayout.draggingOpacity
                : 1
        )
        .onHover { hovering in
            if hovering {
                hoveredID = item.id
                draggingID = nil
            } else if hoveredID == item.id {
                hoveredID = nil
            }
        }
        .onDrag {
            draggingID = item.id
            return NSItemProvider(object: String(describing: item.id) as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: WorkspaceContentTabDropDelegate(
                targetID: item.id,
                draggingID: $draggingID,
                tabsModel: tabsModel,
                reduceMotion: reduceMotion
            )
        )
    }

}

private struct WorkspaceContentTabStripItem: View {
    let item: WorkspaceContentTabItem
    let isSelected: Bool
    let isHovered: Bool
    let isWindowActive: Bool
    let showsLeadingSeparator: Bool
    let position: Int
    let count: Int
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let closeToRight: () -> Void
    let closeAll: () -> Void
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let moveLeft: () -> Void
    let moveRight: () -> Void

    var body: some View {
        ZStack {
            if showsLeadingSeparator {
                HStack {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(
                            width: WorkspaceContentTabStripLayout.hairline,
                            height: WorkspaceContentTabStripLayout.separatorHeight
                        )
                    Spacer()
                }
            }
            surface
        }
        .contentShape(Rectangle())
        .help(item.title)
        .contextMenu {
            Button(AppCopy.current.text("关闭标签页", "Close Tab"), action: close)
            Button(AppCopy.current.text("关闭其他标签页", "Close Other Tabs"), action: closeOthers)
                .disabled(count < 2)
            Button(AppCopy.current.text("关闭右侧标签页", "Close Tabs to the Right"), action: closeToRight)
                .disabled(position == count)
            Button(AppCopy.current.text("关闭所有标签页", "Close All Tabs"), action: closeAll)
            Divider()
            Button(AppCopy.current.text("左移标签页", "Move Tab Left"), action: moveLeft)
                .disabled(!canMoveLeft)
            Button(AppCopy.current.text("右移标签页", "Move Tab Right"), action: moveRight)
                .disabled(!canMoveRight)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.title)
        .accessibilityValue(
            AppCopy.current.text(
                "第 \(position) 个，共 \(count) 个",
                "\(position) of \(count)"
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: AppCopy.current.text("关闭标签页", "Close Tab"), close)
    }

    private var surface: some View {
        ZStack {
            Button(action: select) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: WorkspaceContentTabStripLayout.accessoryWidth)
                    Text(item.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(titleColor)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(width: WorkspaceContentTabStripLayout.accessoryWidth)
                }
                .padding(.horizontal, WorkspaceContentTabStripLayout.accessoryInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                if isSelected || (isHovered && isWindowActive) {
                    Button(AppCopy.current.text("关闭标签页", "Close Tab"), systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: WorkspaceContentTabStripLayout.accessoryWidth,
                            height: WorkspaceContentTabStripLayout.accessoryWidth
                        )
                }
                Spacer()
            }
            .padding(.leading, WorkspaceContentTabStripLayout.accessoryInset)
        }
        .workspaceTabSurface(
            isSelected: isSelected,
            isHovered: isHovered,
            isWindowActive: isWindowActive
        )
    }

    private var titleColor: Color {
        return Color(nsColor: isSelected ? .labelColor : .secondaryLabelColor)
    }
}

private struct WorkspaceContentTabDropDelegate: DropDelegate {
    let targetID: WorkspaceContentTabID
    @Binding var draggingID: WorkspaceContentTabID?
    let tabsModel: WorkspaceContentTabsModel
    let reduceMotion: Bool

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != targetID,
              let destination = tabsModel.contentItems.firstIndex(where: {
                  $0.id == targetID
              })
        else { return }
        if reduceMotion {
            tabsModel.move(draggingID, to: destination)
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                tabsModel.move(draggingID, to: destination)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { draggingID != nil }
    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private struct WorkspaceContentTabDropReset: DropDelegate {
    @Binding var draggingID: WorkspaceContentTabID?
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { draggingID = nil }
    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private extension View {
    @ViewBuilder
    func workspaceTabTrackClipShape() -> some View {
        if #available(macOS 26.0, *) {
            clipShape(Capsule(style: .continuous))
        } else {
            clipped()
        }
    }

    @ViewBuilder
    func workspaceTabTrackSurface() -> some View {
        if #available(macOS 26.0, *) {
            background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        Capsule(style: .continuous).strokeBorder(
                            Color(nsColor: .quinaryLabel),
                            lineWidth: WorkspaceContentTabStripLayout.hairline
                        )
                    )
            )
        } else {
            background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .bottom) {
                    Divider()
                }
        }
    }

    @ViewBuilder
    func workspaceTabSurface(
        isSelected: Bool,
        isHovered: Bool,
        isWindowActive: Bool
    ) -> some View {
        if #available(macOS 26.0, *) {
            if isSelected {
                background(
                    Capsule(style: .continuous).fill(
                        Color(
                            nsColor:
                                .unemphasizedSelectedContentBackgroundColor
                        )
                    )
                )
            } else if isHovered && isWindowActive {
                background(
                    Capsule(style: .continuous).fill(
                        Color(nsColor: .tertiarySystemFill)
                    )
                )
            } else {
                self
            }
        } else if isSelected {
            background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) {
                    Color.accentColor.frame(
                        height: WorkspaceContentTabStripLayout.hairline * 2
                    )
                }
        } else if isHovered && isWindowActive {
            background(Color(nsColor: .quaternarySystemFill))
        } else {
            self
        }
    }

}
