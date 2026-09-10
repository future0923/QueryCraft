import AppKit
import SwiftUI

@MainActor
final class WorkspaceRedisKeyOutlineCoordinator:
    NSObject,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    private static let columnIdentifier = NSUserInterfaceItemIdentifier(
        "redis.keyOutline.name"
    )
    private static let rowIdentifier = NSUserInterfaceItemIdentifier(
        "redis.keyOutline.row"
    )

    private var rootItems: [RedisKeyOutlineItem]
    private var revision: Int
    private var expandsAllItems: Bool
    private var selection: Binding<RedisKeyReference?>
    private var openKey: @MainActor (RedisKeyReference) -> Void
    private var renameKey: @MainActor (RedisKeyReference) -> Void
    private var copyKeyName: @MainActor (RedisKeyReference) -> Void
    private var deleteKey: @MainActor (RedisKeyReference) -> Void
    private var resolveKeyTypes: @MainActor ([RedisKeyReference]) -> Void
    private var typeBatcher: RedisVisibleKeyTypeBatcher
    private let typeResolutionDebounce: Duration
    private var expandedIDs: Set<String> = []
    private weak var outlineView: WorkspaceRedisKeyOutlineNativeView?
    private var isSynchronizingSelection = false
    private var isSynchronizingExpansion = false
    private var contextMenuReference: RedisKeyReference?
    private var typeResolutionTask: Task<Void, Never>?
    private var typeResolutionGeneration = 0

    init(
        nodes: [RedisKeyTreeNode],
        revision: Int,
        expandsAllItems: Bool,
        selection: Binding<RedisKeyReference?>,
        openKey: @escaping @MainActor (RedisKeyReference) -> Void,
        renameKey: @escaping @MainActor (RedisKeyReference) -> Void,
        copyKeyName: @escaping @MainActor (RedisKeyReference) -> Void,
        deleteKey: @escaping @MainActor (RedisKeyReference) -> Void,
        automaticallyResolvesKeyTypes: Bool = true,
        typeResolutionBatchSize: Int = 50,
        resolveKeyTypes: @escaping @MainActor ([RedisKeyReference]) -> Void = {
            _ in
        },
        typeResolutionDebounce: Duration = .milliseconds(80)
    ) {
        rootItems = nodes.map(RedisKeyOutlineItem.init)
        self.revision = revision
        self.expandsAllItems = expandsAllItems
        self.selection = selection
        self.openKey = openKey
        self.renameKey = renameKey
        self.copyKeyName = copyKeyName
        self.deleteKey = deleteKey
        typeBatcher = RedisVisibleKeyTypeBatcher(
            isEnabled: automaticallyResolvesKeyTypes,
            maximumBatchSize: typeResolutionBatchSize
        )
        self.resolveKeyTypes = resolveKeyTypes
        self.typeResolutionDebounce = typeResolutionDebounce
    }

    func makeScrollView() -> NSScrollView {
        let outlineView = WorkspaceRedisKeyOutlineNativeView()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.usesAutomaticRowHeights = false
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = 14
        outlineView.style = .sourceList
        outlineView.selectionHighlightStyle = .regular
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.backgroundColor = .clear
        outlineView.setAccessibilityIdentifier("redis.keyOutline")

        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.togglePrefixAtRow = { [weak self] row in
            self?.togglePrefix(at: row) == true
        }
        outlineView.contextMenuForRow = { [weak self] row in
            self?.contextMenu(for: row)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        self.outlineView = outlineView
        applyExpansionState()
        syncSelection()
        return scrollView
    }

    func update(
        nodes: [RedisKeyTreeNode],
        revision: Int,
        expandsAllItems: Bool,
        selection: Binding<RedisKeyReference?>,
        openKey: @escaping @MainActor (RedisKeyReference) -> Void,
        renameKey: @escaping @MainActor (RedisKeyReference) -> Void,
        copyKeyName: @escaping @MainActor (RedisKeyReference) -> Void,
        deleteKey: @escaping @MainActor (RedisKeyReference) -> Void,
        automaticallyResolvesKeyTypes: Bool = true,
        typeResolutionBatchSize: Int = 50,
        resolveKeyTypes: @escaping @MainActor ([RedisKeyReference]) -> Void = {
            _ in
        }
    ) {
        self.selection = selection
        self.openKey = openKey
        self.renameKey = renameKey
        self.copyKeyName = copyKeyName
        self.deleteKey = deleteKey
        self.resolveKeyTypes = resolveKeyTypes
        let wasResolvingTypes = typeBatcher.isEnabled
        typeBatcher.configure(
            isEnabled: automaticallyResolvesKeyTypes,
            maximumBatchSize: typeResolutionBatchSize
        )
        if !automaticallyResolvesKeyTypes {
            cancelPendingTypeResolution()
        }
        let expansionModeChanged = self.expandsAllItems != expandsAllItems
        self.expandsAllItems = expandsAllItems
        guard let outlineView else { return }
        var didReload = false
        if self.revision != revision {
            cancelPendingTypeResolution()
            self.revision = revision
            rootItems = nodes.map(RedisKeyOutlineItem.init)
            outlineView.reloadData()
            didReload = true
        }
        if didReload || expansionModeChanged {
            applyExpansionState()
        }
        syncSelection()
        if automaticallyResolvesKeyTypes && (!wasResolvingTypes || didReload) {
            enqueueVisibleUnknownKeyTypes()
        }
    }

    private func children(of item: RedisKeyOutlineItem) -> [RedisKeyOutlineItem] {
        if let children = item.children { return children }
        let children = item.node.children.map(RedisKeyOutlineItem.init)
        item.children = children
        return children
    }

    private func togglePrefix(at row: Int) -> Bool {
        guard let outlineView,
              let item = outlineView.item(atRow: row) as? RedisKeyOutlineItem,
              case .prefix = item.node.content
        else { return false }
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
            if !expandsAllItems {
                expandedIDs.remove(item.node.id)
            }
            syncSelection()
        } else {
            outlineView.expandItem(item)
            if !expandsAllItems {
                expandedIDs.insert(item.node.id)
            }
        }
        return true
    }

    private func applyExpansionState() {
        guard let outlineView else { return }
        let wasSynchronizingSelection = isSynchronizingSelection
        isSynchronizingSelection = true
        isSynchronizingExpansion = true
        defer {
            isSynchronizingExpansion = false
            isSynchronizingSelection = wasSynchronizingSelection
        }
        if expandsAllItems {
            for item in rootItems {
                outlineView.expandItem(item, expandChildren: true)
            }
        } else {
            for item in rootItems {
                outlineView.collapseItem(item, collapseChildren: true)
            }
            restoreExpandedItems(rootItems)
        }
    }

    private func restoreExpandedItems(_ items: [RedisKeyOutlineItem]) {
        guard let outlineView else { return }
        for item in items where expandedIDs.contains(item.node.id) {
            outlineView.expandItem(item)
            restoreExpandedItems(children(of: item))
        }
    }

    private func syncSelection() {
        guard let outlineView, !isSynchronizingSelection else { return }
        let selectedReference = selection.wrappedValue
        let selectedRow = (0..<outlineView.numberOfRows).first { row in
            let item = outlineView.item(atRow: row) as? RedisKeyOutlineItem
            return item?.node.reference == selectedReference
        }
        let target = selectedRow.map(IndexSet.init(integer:)) ?? []
        guard outlineView.selectedRowIndexes != target else { return }
        isSynchronizingSelection = true
        outlineView.selectRowIndexes(target, byExtendingSelection: false)
        if let selectedRow {
            outlineView.scrollRowToVisible(selectedRow)
        }
        isSynchronizingSelection = false
    }

    private func contextMenu(for row: Int) -> NSMenu? {
        guard let outlineView,
              let item = outlineView.item(atRow: row) as? RedisKeyOutlineItem,
              let reference = item.node.reference
        else { return nil }
        contextMenuReference = reference
        let menu = NSMenu()
        menu.addItem(menuItem(
            title: AppCopy.current.text("打开 Key", "Open Key"),
            action: #selector(openContextKey)
        ))
        menu.addItem(menuItem(
            title: AppCopy.current.text("重命名 Key", "Rename Key"),
            action: #selector(renameContextKey)
        ))
        menu.addItem(menuItem(
            title: AppCopy.current.text("复制 Key 名称", "Copy Key Name"),
            action: #selector(copyContextKeyName)
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: AppCopy.current.text("删除 Key", "Delete Key"),
            action: #selector(deleteContextKey)
        ))
        return menu
    }

    private func menuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openContextKey() {
        guard let contextMenuReference else { return }
        openKey(contextMenuReference)
    }

    @objc private func copyContextKeyName() {
        guard let contextMenuReference else { return }
        copyKeyName(contextMenuReference)
    }

    @objc private func renameContextKey() {
        guard let contextMenuReference else { return }
        renameKey(contextMenuReference)
    }

    @objc private func deleteContextKey() {
        guard let contextMenuReference else { return }
        deleteKey(contextMenuReference)
    }
}

extension WorkspaceRedisKeyOutlineCoordinator {
    func outlineView(
        _ outlineView: NSOutlineView,
        rowViewForItem item: Any
    ) -> NSTableRowView? {
        let rowView = WorkspaceRedisKeyOutlineSelectionRowView()
        if let item = item as? RedisKeyOutlineItem {
            rowView.suppressesSelectionHighlight = item.node.reference == nil
        }
        return rowView
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        guard let item = item as? RedisKeyOutlineItem else {
            return rootItems.count
        }
        return item.node.children.count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        let items = if let item = item as? RedisKeyOutlineItem {
            children(of: item)
        } else {
            rootItems
        }
        return items[index]
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        isItemExpandable item: Any
    ) -> Bool {
        guard let item = item as? RedisKeyOutlineItem else { return false }
        return !item.node.children.isEmpty
    }
}

extension WorkspaceRedisKeyOutlineCoordinator {
    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let item = item as? RedisKeyOutlineItem else { return nil }
        let rowView: WorkspaceRedisKeyOutlineRowView
        if let reused = outlineView.makeView(
            withIdentifier: Self.rowIdentifier,
            owner: self
        ) as? WorkspaceRedisKeyOutlineRowView {
            rowView = reused
        } else {
            rowView = WorkspaceRedisKeyOutlineRowView()
            rowView.identifier = Self.rowIdentifier
        }
        rowView.configure(node: item.node)
        if let reference = item.node.reference, reference.type == .unknown {
            enqueueTypeResolution(reference)
        }
        return rowView
    }

    private func enqueueTypeResolution(_ reference: RedisKeyReference) {
        guard typeBatcher.enqueue(reference) else { return }
        scheduleTypeResolutionIfNeeded()
    }

    private func enqueueVisibleUnknownKeyTypes() {
        guard let outlineView else { return }
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row)
                as? RedisKeyOutlineItem,
                let reference = item.node.reference,
                reference.type == .unknown
            else { continue }
            _ = typeBatcher.enqueue(reference)
        }
        scheduleTypeResolutionIfNeeded()
    }

    private func scheduleTypeResolutionIfNeeded() {
        guard typeBatcher.isEnabled,
              !typeBatcher.isEmpty,
              typeResolutionTask == nil
        else { return }
        let generation = typeResolutionGeneration
        let debounce = typeResolutionDebounce
        typeResolutionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  generation == typeResolutionGeneration,
                  typeBatcher.isEnabled
            else { return }
            typeResolutionTask = nil
            let references = typeBatcher.nextBatch()
            guard !references.isEmpty else { return }
            resolveKeyTypes(references)
            scheduleTypeResolutionIfNeeded()
        }
    }

    private func cancelPendingTypeResolution() {
        typeResolutionGeneration += 1
        typeResolutionTask?.cancel()
        typeResolutionTask = nil
        typeBatcher.removeAll()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldSelectItem item: Any
    ) -> Bool {
        (item as? RedisKeyOutlineItem)?.node.reference != nil
    }

    func outlineViewSelectionDidChange(
        _ notification: Notification
    ) {
        guard !isSynchronizingSelection, let outlineView else { return }
        guard outlineView.selectedRow >= 0,
              let item = outlineView.item(atRow: outlineView.selectedRow)
                as? RedisKeyOutlineItem,
              let reference = item.node.reference
        else {
            if outlineView.selectedRow >= 0 {
                isSynchronizingSelection = true
                outlineView.deselectAll(nil)
                isSynchronizingSelection = false
            }
            return
        }
        selection.wrappedValue = reference
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isSynchronizingExpansion, !expandsAllItems else { return }
        guard let item = notification.userInfo?["NSObject"]
            as? RedisKeyOutlineItem
        else { return }
        expandedIDs.insert(item.node.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isSynchronizingExpansion else { return }
        defer { syncSelection() }
        guard !expandsAllItems else { return }
        guard let item = notification.userInfo?["NSObject"]
            as? RedisKeyOutlineItem
        else { return }
        expandedIDs.remove(item.node.id)
    }
}

struct RedisVisibleKeyTypeBatcher {
    private(set) var isEnabled: Bool
    private(set) var maximumBatchSize: Int
    private var pendingReferences: Set<RedisKeyReference> = []

    init(isEnabled: Bool, maximumBatchSize: Int) {
        self.isEnabled = isEnabled
        self.maximumBatchSize = max(1, maximumBatchSize)
    }

    var isEmpty: Bool { pendingReferences.isEmpty }

    mutating func configure(isEnabled: Bool, maximumBatchSize: Int) {
        self.isEnabled = isEnabled
        self.maximumBatchSize = max(1, maximumBatchSize)
        if !isEnabled {
            pendingReferences.removeAll()
        }
    }

    @discardableResult
    mutating func enqueue(_ reference: RedisKeyReference) -> Bool {
        guard isEnabled else { return false }
        pendingReferences.insert(reference)
        return true
    }

    mutating func nextBatch() -> [RedisKeyReference] {
        guard isEnabled else { return [] }
        let batch = Array(pendingReferences.prefix(maximumBatchSize))
        pendingReferences.subtract(batch)
        return batch
    }

    mutating func removeAll() {
        pendingReferences.removeAll()
    }
}
