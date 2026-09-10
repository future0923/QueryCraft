import AppKit
import SwiftUI

struct ConnectionProfilesOutlineView: NSViewRepresentable {
    let groups: [ConnectionGroup]
    let profiles: [ConnectionProfile]
    let openProfile: (ConnectionProfile) -> Void
    let createProfile: (ConnectionGroup.ID?) -> Void
    let editProfile: (ConnectionProfile) -> Void
    let duplicateProfile: (ConnectionProfile) -> Void
    let deleteProfile: (ConnectionProfile) -> Void
    let renameGroup: (ConnectionGroup) -> Void
    let deleteGroup: (ConnectionGroup) -> Void
    let moveProfile:
        (
            ConnectionProfile.ID,
            ConnectionGroup.ID?,
            ConnectionProfile.ID?
        ) -> Void
    let moveGroup:
        (ConnectionGroup.ID, ConnectionGroup.ID?) -> Void

    func makeCoordinator() -> ConnectionProfilesOutlineCoordinator {
        ConnectionProfilesOutlineCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = 14
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        outlineView.autosaveExpandedItems = false
        outlineView.backgroundColor = .clear

        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier(
                "ConnectionProfilesColumn"
            )
        )
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(
            ConnectionProfilesOutlineCoordinator.handleDoubleClick
        )
        outlineView.registerForDraggedTypes([
            ConnectionProfilesOutlineCoordinator.dragPasteboardType
        ])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        context.coordinator.attach(outlineView: outlineView)
        context.coordinator.update(from: self)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        return scrollView
    }

    func updateNSView(
        _ nsView: NSScrollView,
        context: Context
    ) {
        context.coordinator.update(from: self)
    }
}
