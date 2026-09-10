import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ConnectionProfilesOutlineCoordinator:
    NSObject,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate,
    NSMenuDelegate
{
    static let dragPasteboardType = NSPasteboard.PasteboardType(
        UTType.queryCraftConnectionItem.identifier
    )

    private weak var outlineView: NSOutlineView?
    private var groups: [ConnectionGroup] = []
    private var profiles: [ConnectionProfile] = []
    private var nodeCache: [String: ConnectionProfilesOutlineNode] = [:]
    private var contextNode: ConnectionProfilesOutlineNode?
    private var collapsedSectionIDs: Set<String> = []
    private var isApplyingExpansion = false

    private var openProfile: ((ConnectionProfile) -> Void)?
    private var createProfile: ((ConnectionGroup.ID?) -> Void)?
    private var editProfile: ((ConnectionProfile) -> Void)?
    private var duplicateProfile: ((ConnectionProfile) -> Void)?
    private var deleteProfile: ((ConnectionProfile) -> Void)?
    private var renameGroup: ((ConnectionGroup) -> Void)?
    private var deleteGroup: ((ConnectionGroup) -> Void)?
    private var moveProfile:
        ((
            ConnectionProfile.ID,
            ConnectionGroup.ID?,
            ConnectionProfile.ID?
        ) -> Void)?
    private var moveGroup:
        ((ConnectionGroup.ID, ConnectionGroup.ID?) -> Void)?

    func attach(outlineView: NSOutlineView) {
        self.outlineView = outlineView
    }

    func update(from view: ConnectionProfilesOutlineView) {
        openProfile = view.openProfile
        createProfile = view.createProfile
        editProfile = view.editProfile
        duplicateProfile = view.duplicateProfile
        deleteProfile = view.deleteProfile
        renameGroup = view.renameGroup
        deleteGroup = view.deleteGroup
        moveProfile = view.moveProfile
        moveGroup = view.moveGroup

        guard groups != view.groups || profiles != view.profiles else {
            return
        }
        groups = view.groups
        profiles = view.profiles
        reload()
    }

    private func reload() {
        guard let outlineView else { return }
        outlineView.reloadData()
        isApplyingExpansion = true
        for node in rootNodes()
        where !collapsedSectionIDs.contains(node.id) {
            outlineView.expandItem(node)
        }
        isApplyingExpansion = false
    }

    private func node(
        id: String,
        kind: ConnectionProfilesOutlineNode.Kind
    ) -> ConnectionProfilesOutlineNode {
        if let existing = nodeCache[id] {
            existing.kind = kind
            return existing
        }
        let created = ConnectionProfilesOutlineNode(id: id, kind: kind)
        nodeCache[id] = created
        return created
    }

    private func rootNodes() -> [ConnectionProfilesOutlineNode] {
        var result = [
            node(id: "ungrouped", kind: .ungrouped)
        ]
        result.append(
            contentsOf: groups.map { group in
                node(id: "group:\(group.id)", kind: .group(group))
            }
        )
        return result
    }

    private func childNodes(
        of item: ConnectionProfilesOutlineNode?
    ) -> [ConnectionProfilesOutlineNode] {
        guard let item else { return rootNodes() }
        let groupID: ConnectionGroup.ID?
        switch item.kind {
        case .ungrouped:
            groupID = nil
        case .group(let group):
            groupID = group.id
        case .profile:
            return []
        }
        return profiles
            .filter { $0.groupID == groupID }
            .map { profile in
                node(
                    id: "profile:\(profile.id)",
                    kind: .profile(profile)
                )
            }
    }

    private func sectionNode(
        for groupID: ConnectionGroup.ID?
    ) -> ConnectionProfilesOutlineNode? {
        if let groupID {
            return rootNodes().first { node in
                guard case .group(let group) = node.kind else {
                    return false
                }
                return group.id == groupID
            }
        }
        return rootNodes().first {
            if case .ungrouped = $0.kind { return true }
            return false
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        childNodes(
            of: item as? ConnectionProfilesOutlineNode
        ).count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        childNodes(
            of: item as? ConnectionProfilesOutlineNode
        )[index]
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        isItemExpandable item: Any
    ) -> Bool {
        guard let node = item as? ConnectionProfilesOutlineNode else {
            return false
        }
        switch node.kind {
        case .ungrouped, .group:
            return !childNodes(of: node).isEmpty
        case .profile:
            return false
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? ConnectionProfilesOutlineNode else {
            return nil
        }
        switch node.kind {
        case .ungrouped:
            return groupHostingView(
                title: AppCopy.current.text("未分组", "Ungrouped"),
                profileCount: profiles(in: nil).count,
                systemImage: "tray.full",
                accessibilityIdentifier: "connectionGroup.ungrouped"
            )
        case .group(let group):
            return groupHostingView(
                title: group.name,
                profileCount: profiles(in: group.id).count,
                systemImage: "folder.fill",
                accessibilityIdentifier: "connectionGroup.\(group.id)"
            )
        case .profile(let profile):
            let hostingView = ConnectionProfileHostingView(
                profile: profile
            )
            hostingView.setAccessibilityIdentifier(
                "connectionProfileRow"
            )
            return hostingView
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldSelectItem item: Any
    ) -> Bool {
        guard let node = item as? ConnectionProfilesOutlineNode else {
            return false
        }
        switch node.kind {
        case .profile, .group:
            return true
        case .ungrouped:
            return false
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        rowViewForItem item: Any
    ) -> NSTableRowView? {
        guard let node = item as? ConnectionProfilesOutlineNode else {
            return nil
        }
        let rowView = NSTableRowView()
        switch node.kind {
        case .ungrouped, .group:
            rowView.selectionHighlightStyle = .none
        case .profile:
            let rowView = ConnectionProfileTableRowView()
            rowView.selectionHighlightStyle = .regular
            return rowView
        }
        return rowView
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        heightOfRowByItem item: Any
    ) -> CGFloat {
        guard let node = item as? ConnectionProfilesOutlineNode else {
            return 28
        }
        if case .profile = node.kind {
            return 44
        }
        return 28
    }

    private func groupHostingView(
        title: String,
        profileCount: Int,
        systemImage: String?,
        accessibilityIdentifier: String
    ) -> NSView {
        NSHostingView(
            rootView: ConnectionGroupHeader(
                title: title,
                profileCount: profileCount,
                systemImage: systemImage,
                accessibilityIdentifier: accessibilityIdentifier
            )
            .padding(.trailing, 6)
        )
    }

    private func profiles(
        in groupID: ConnectionGroup.ID?
    ) -> [ConnectionProfile] {
        profiles.filter { $0.groupID == groupID }
    }

    @objc func handleDoubleClick() {
        guard
            let outlineView,
            outlineView.clickedRow >= 0,
            let node = outlineView.item(
                atRow: outlineView.clickedRow
            ) as? ConnectionProfilesOutlineNode
        else {
            return
        }
        switch node.kind {
        case .profile(let profile):
            openProfile?(profile)
        case .ungrouped, .group:
            break
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard
            let node = notification.userInfo?[
                "NSObject"
            ] as? ConnectionProfilesOutlineNode
        else {
            return
        }
        guard !isApplyingExpansion else {
            return
        }
        collapsedSectionIDs.remove(node.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard
            let node = notification.userInfo?[
                "NSObject"
            ] as? ConnectionProfilesOutlineNode
        else {
            return
        }
        guard !isApplyingExpansion else {
            return
        }
        collapsedSectionIDs.insert(node.id)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let node = item as? ConnectionProfilesOutlineNode else {
            return nil
        }
        let dragItem: ConnectionDragItem
        switch node.kind {
        case .profile(let profile):
            dragItem = ConnectionDragItem(
                kind: .profile,
                id: profile.id
            )
        case .group(let group):
            dragItem = ConnectionDragItem(
                kind: .group,
                id: group.id
            )
        case .ungrouped:
            return nil
        }
        guard let data = try? JSONEncoder().encode(dragItem) else {
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: Self.dragPasteboardType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard
            let dragItem = dragItem(from: info)
        else {
            return []
        }
        switch dragItem.kind {
        case .profile:
            return validateProfileDrop(
                outlineView,
                proposedItem: item,
                proposedChildIndex: index
            )
        case .group:
            return validateGroupDrop(
                outlineView,
                proposedItem: item,
                proposedChildIndex: index
            )
        }
    }

    private func validateProfileDrop(
        _ outlineView: NSOutlineView,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let node = item as? ConnectionProfilesOutlineNode else {
            return []
        }
        switch node.kind {
        case .ungrouped, .group:
            let childIndex = index == NSOutlineViewDropOnItemIndex
                ? childNodes(of: node).count
                : max(0, index)
            outlineView.setDropItem(
                node,
                dropChildIndex: childIndex
            )
            return .move
        case .profile(let profile):
            guard
                let section = sectionNode(for: profile.groupID),
                let childIndex = profiles(in: profile.groupID)
                    .firstIndex(where: { $0.id == profile.id })
            else {
                return []
            }
            outlineView.setDropItem(
                section,
                dropChildIndex: childIndex
            )
            return .move
        }
    }

    private func validateGroupDrop(
        _ outlineView: NSOutlineView,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if item == nil {
            outlineView.setDropItem(
                nil,
                dropChildIndex: max(1, index)
            )
            return .move
        }
        guard
            let node = item as? ConnectionProfilesOutlineNode,
            case .group(let group) = node.kind,
            let groupIndex = groups.firstIndex(where: {
                $0.id == group.id
            })
        else {
            return []
        }
        outlineView.setDropItem(
            nil,
            dropChildIndex: groupIndex + 1
        )
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let dragItem = dragItem(from: info) else {
            return false
        }
        switch dragItem.kind {
        case .profile:
            return acceptProfileDrop(
                id: dragItem.id,
                section: item as? ConnectionProfilesOutlineNode,
                childIndex: index
            )
        case .group:
            return acceptGroupDrop(
                id: dragItem.id,
                rootChildIndex: index
            )
        }
    }

    private func acceptProfileDrop(
        id: ConnectionProfile.ID,
        section: ConnectionProfilesOutlineNode?,
        childIndex: Int
    ) -> Bool {
        guard let section else { return false }
        let targetGroupID: ConnectionGroup.ID?
        switch section.kind {
        case .ungrouped:
            targetGroupID = nil
        case .group(let group):
            targetGroupID = group.id
        case .profile:
            return false
        }

        let destination = profiles(in: targetGroupID)
        let originalIndex = destination.firstIndex {
            $0.id == id
        }
        var insertionIndex = min(
            max(0, childIndex),
            destination.count
        )
        if let originalIndex, originalIndex < insertionIndex {
            insertionIndex -= 1
        }
        let remaining = destination.filter { $0.id != id }
        let beforeProfileID = insertionIndex < remaining.count
            ? remaining[insertionIndex].id
            : nil
        moveProfile?(id, targetGroupID, beforeProfileID)
        return true
    }

    private func acceptGroupDrop(
        id: ConnectionGroup.ID,
        rootChildIndex: Int
    ) -> Bool {
        guard let originalIndex = groups.firstIndex(where: {
            $0.id == id
        }) else {
            return false
        }
        var insertionIndex = min(
            max(0, rootChildIndex - 1),
            groups.count
        )
        if originalIndex < insertionIndex {
            insertionIndex -= 1
        }
        let remaining = groups.filter { $0.id != id }
        let beforeGroupID = insertionIndex < remaining.count
            ? remaining[insertionIndex].id
            : nil
        moveGroup?(id, beforeGroupID)
        return true
    }

    private func dragItem(
        from info: NSDraggingInfo
    ) -> ConnectionDragItem? {
        guard
            let data = info.draggingPasteboard
                .data(forType: Self.dragPasteboardType)
        else {
            return nil
        }
        return try? JSONDecoder().decode(
            ConnectionDragItem.self,
            from: data
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard
            let outlineView,
            outlineView.clickedRow >= 0,
            let node = outlineView.item(
                atRow: outlineView.clickedRow
            ) as? ConnectionProfilesOutlineNode
        else {
            contextNode = nil
            return
        }
        contextNode = node
        switch node.kind {
        case .profile:
            addMenuItem(
                to: menu,
                title: AppCopy.current.text("在新窗口中打开", "Open in New Window"),
                systemImage: "arrow.forward",
                action: #selector(openContextProfile)
            )
            menu.addItem(.separator())
            addMenuItem(
                to: menu,
                title: AppCopy.current.text("编辑", "Edit"),
                systemImage: "pencil",
                action: #selector(editContextProfile)
            )
            addMenuItem(
                to: menu,
                title: AppCopy.current.text("复制", "Duplicate"),
                systemImage: "plus.square.on.square",
                action: #selector(duplicateContextProfile)
            )
            menu.addItem(.separator())
            addMenuItem(
                to: menu,
                title: AppCopy.current.text("删除", "Delete"),
                systemImage: "trash",
                action: #selector(deleteContextProfile)
            )
        case .ungrouped:
            addMenuItem(
                to: menu,
                title: AppCopy.current.text("新建连接", "New Connection"),
                systemImage: "plus",
                action: #selector(createContextProfile)
            )
        case .group:
            addMenuItem(
                to: menu,
                title: AppCopy.current.text("新建连接", "New Connection"),
                systemImage: "plus",
                action: #selector(createContextProfile)
            )
            menu.addItem(.separator())
            addMenuItem(
                to: menu,
                title: AppCopy.current.text("重命名", "Rename"),
                systemImage: "pencil",
                action: #selector(renameContextGroup)
            )
            addMenuItem(
                to: menu,
                title: AppCopy.current.text("删除分组", "Delete Group"),
                systemImage: "trash",
                action: #selector(deleteContextGroup)
            )
        }
    }

    private func addMenuItem(
        to menu: NSMenu,
        title: String,
        systemImage: String,
        action: Selector
    ) {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: nil
        )
        menu.addItem(item)
    }

    @objc private func openContextProfile() {
        withContextProfile(openProfile)
    }

    @objc private func editContextProfile() {
        withContextProfile(editProfile)
    }

    @objc private func duplicateContextProfile() {
        withContextProfile(duplicateProfile)
    }

    @objc private func deleteContextProfile() {
        withContextProfile(deleteProfile)
    }

    private func withContextProfile(
        _ action: ((ConnectionProfile) -> Void)?
    ) {
        guard
            let contextNode,
            case .profile(let profile) = contextNode.kind
        else {
            return
        }
        action?(profile)
    }

    @objc private func createContextProfile() {
        guard let contextNode else { return }
        switch contextNode.kind {
        case .ungrouped:
            createProfile?(nil)
        case .group(let group):
            createProfile?(group.id)
        case .profile:
            break
        }
    }

    @objc private func renameContextGroup() {
        withContextGroup(renameGroup)
    }

    @objc private func deleteContextGroup() {
        withContextGroup(deleteGroup)
    }

    private func withContextGroup(
        _ action: ((ConnectionGroup) -> Void)?
    ) {
        guard
            let contextNode,
            case .group(let group) = contextNode.kind
        else {
            return
        }
        action?(group)
    }
}
