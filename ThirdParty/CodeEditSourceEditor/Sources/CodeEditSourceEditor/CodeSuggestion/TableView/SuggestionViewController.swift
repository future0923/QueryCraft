//
//  SuggestionViewController.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit
import SwiftUI

class SuggestionViewController: NSViewController {
    var tintView: NSView = NSView()
    var tableView: NSTableView = NSTableView()
    var scrollView: NSScrollView = NSScrollView()
    var noItemsLabel: NSTextField = NSTextField(labelWithString: "No Completions")
    var previewView: CodeSuggestionPreviewView = CodeSuggestionPreviewView()

    var scrollViewHeightConstraint: NSLayoutConstraint?
    var viewHeightConstraint: NSLayoutConstraint?
    var viewWidthConstraint: NSLayoutConstraint?

    var cachedFont: NSFont?
    private var cachedRowHeight: CGFloat?
    private var renderedItemIdentities: [String] = []
    private var isRestoringSelection = false

    weak var model: SuggestionViewModel?

    /// An event monitor for keyboard events
    private var localEventMonitor: Any?

    weak var windowController: SuggestionController?

    override func loadView() {
        let rootView = CompletionAppearanceView()
        rootView.onAppearanceChanged = { [weak self] in
            guard let self, let controller = self.model?.activeTextView else { return }
            self.styleView(using: controller)
        }
        view = rootView
        view.wantsLayer = true
        view.layer?.cornerRadius = 8.5

        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = 8.5
        view.addSubview(tintView)

        configureTableView()
        configureScrollView()

        noItemsLabel.textColor = .secondaryLabelColor
        noItemsLabel.alignment = .center
        noItemsLabel.translatesAutoresizingMaskIntoConstraints = false
        noItemsLabel.isHidden = false

        previewView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(noItemsLabel)
        view.addSubview(scrollView)
        view.addSubview(previewView)

        NSLayoutConstraint.activate([
            tintView.topAnchor.constraint(equalTo: view.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            noItemsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noItemsLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            noItemsLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: previewView.topAnchor),

            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        setupEventMonitors()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }

    private func setupEventMonitors() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self = self else { return event }

            switch event.type {
            case .keyDown:
                return checkKeyDownEvents(event)
            default:
                return event
            }
        }
    }

    private func checkKeyDownEvents(_ event: NSEvent) -> NSEvent? {
        guard let windowController,
              windowController.isVisible,
              let activeTextView = model?.activeTextView,
              let activeWindow = activeTextView.view.window,
              event.windowNumber == activeWindow.windowNumber,
              activeWindow.firstResponder === activeTextView.textView
        else {
            return event
        }

        switch event.keyCode {
        case 53: // Escape
            windowController.close()
            return nil

        case 125:  // Down Arrow
            moveSelection(by: 1)
            return nil

        case 126:  // Up Arrow
            moveSelection(by: -1)
            return nil

        case let keyCode
            where activeTextView.completionAcceptanceKey.accepts(
                keyCode: keyCode
            ):
            self.applySelectedItem()
            return nil

        default:
            return event
        }
    }

    func styleView(using controller: TextViewController) {
        noItemsLabel.font = controller.font
        previewView.font = controller.font
        previewView.documentationFont = controller.font
        let appearance = view.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let themeBackground = controller.theme.background.resolved(for: appearance)

        view.layer?.backgroundColor = NSColor.windowBackgroundColor
            .resolved(for: appearance)
            .cgColor
        if themeBackground == .clear {
            tintView.layer?.backgroundColor = .clear
        } else if isDark {
            tintView.layer?.backgroundColor = themeBackground.cgColor
        } else if let color = themeBackground.usingColorSpace(.deviceRGB) {
            tintView.layer?.backgroundColor = NSColor(
                red: color.redComponent * 0.95,
                green: color.greenComponent * 0.95,
                blue: color.blueComponent * 0.95,
                alpha: 1
            ).cgColor
        } else {
            tintView.layer?.backgroundColor = themeBackground.cgColor
        }

        noItemsLabel.textColor = NSColor.secondaryLabelColor
            .resolved(for: appearance)
        previewView.refreshAppearance()
        tableView.reloadData()
        tableView.needsDisplay = true
    }

    private func measureAndLockInitialSize(using controller: TextViewController?) {
        guard model?.items.isEmpty == false && tableView.numberOfRows > 0 else {
            let proposedSize = NSSize(
                width: 280,
                height: noItemsLabel.fittingSize.height + 20
            )
            let size = windowController?.lockedCompletionSize(for: proposedSize)
                ?? proposedSize
            preferredContentSize = size
            windowController?.updateWindowSize(newSize: size)
            return
        }

        if controller != nil {
            cachedFont = controller?.font
        }

        let font = controller?.font ?? cachedFont ?? NSFont.systemFont(ofSize: 12)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let widestText = model?.items.reduce(CGFloat.zero) { width, item in
            let labelWidth = (item.label as NSString).size(withAttributes: attributes).width
            let detailWidth = item.detail.map {
                ($0 as NSString).size(withAttributes: attributes).width
            } ?? 0
            return max(width, labelWidth + detailWidth)
        } ?? 0
        let textWidth = min(widestText, font.charWidth * 64)
        let rowChromeWidth = CodeSuggestionLabelView.HORIZONTAL_PADDING * 2
            + font.pointSize + CodeSuggestionLabelView.ICON_WIDTH_PADDING
            + CodeSuggestionLabelView.ICON_TEXT_SPACING
            + CodeSuggestionLabelView.METADATA_SPACING
            + 12
        let availableScreenWidth = controller?.view.window?.screen?.visibleFrame.width
            ?? NSScreen.main?.visibleFrame.width
            ?? 800
        let newWidth = min(
            max(ceil(textWidth + rowChromeWidth + 24), 280),
            max(280, availableScreenWidth - 44)
        )

        let rowHeight: CGFloat
        if let cachedRowHeight {
            rowHeight = cachedRowHeight
        } else {
            tableView.tableColumns.first?.width = newWidth
            tableView.layoutSubtreeIfNeeded()
            guard let rowView = tableView.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            ) else {
                return
            }
            rowView.frame.size.width = newWidth
            rowView.layoutSubtreeIfNeeded()
            rowHeight = max(
                rowView.fittingSize.height,
                rowView.intrinsicContentSize.height
            )
            cachedRowHeight = rowHeight
        }

        let numberOfVisibleRows = min(CGFloat(model?.items.count ?? 0), SuggestionController.MAX_VISIBLE_ROWS)
        previewView.setPreferredMaxLayoutWidth(width: newWidth)
        let proposedScrollHeight = rowHeight * numberOfVisibleRows
            + SuggestionController.WINDOW_PADDING * 2
        let proposedHeight = proposedScrollHeight + previewView.fittingSize.height
        let proposedSize = NSSize(width: newWidth, height: proposedHeight)
        let sessionSize = windowController?.lockedCompletionSize(for: proposedSize)
            ?? proposedSize
        let sessionScrollHeight = max(
            0,
            sessionSize.height - previewView.fittingSize.height
        )

        if let scrollViewHeightConstraint,
           let viewHeightConstraint,
           let viewWidthConstraint
        {
            scrollViewHeightConstraint.constant = sessionScrollHeight
            viewHeightConstraint.constant = sessionSize.height
            viewWidthConstraint.constant = sessionSize.width
        } else {
            scrollViewHeightConstraint = scrollView.heightAnchor.constraint(
                equalToConstant: sessionScrollHeight
            )
            viewHeightConstraint = view.heightAnchor.constraint(
                equalToConstant: sessionSize.height
            )
            viewWidthConstraint = view.widthAnchor.constraint(
                equalToConstant: sessionSize.width
            )

            viewHeightConstraint?.isActive = true
            viewWidthConstraint?.isActive = true
            scrollViewHeightConstraint?.isActive = true
        }

        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        preferredContentSize = sessionSize
        windowController?.updateWindowSize(newSize: sessionSize)
    }

    func configureTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.allowsEmptySelection = false
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = true
        tableView.gridStyleMask = []
        tableView.target = self
        tableView.action = #selector(tableViewClicked(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemsCell"))
        tableView.addTableColumn(column)
    }

    func configureScrollView() {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = NoSlotScroller()
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.contentInsets = NSEdgeInsets(
            top: SuggestionController.WINDOW_PADDING,
            left: 0,
            bottom: SuggestionController.WINDOW_PADDING,
            right: 0
        )
    }

    func renderInitialCandidates(using controller: TextViewController) {
        cachedRowHeight = nil
        commitCandidates(isNewSession: true)
        measureAndLockInitialSize(using: controller)
    }

    func renderVisibleCandidateRefresh() {
        commitCandidates(isNewSession: false)
        measureAndLockInitialSize(using: model?.activeTextView)
    }

    private func commitCandidates(isNewSession: Bool) {
        guard let model else { return }

        let oldSelectedIdentity: String? = if !isNewSession,
           tableView.selectedRow >= 0,
           tableView.selectedRow < renderedItemIdentities.count
        {
            renderedItemIdentities[tableView.selectedRow]
        } else {
            nil
        }
        let oldScrollOrigin = scrollView.contentView.bounds.origin

        noItemsLabel.isHidden = !model.items.isEmpty
        scrollView.isHidden = model.items.isEmpty
        previewView.isHidden = model.items.isEmpty
        renderedItemIdentities = model.items.map(\.completionIdentity)
        tableView.reloadData()

        guard !model.items.isEmpty else { return }
        isRestoringSelection = true
        defer { isRestoringSelection = false }

        if let oldSelectedIdentity,
           let selectedRow = renderedItemIdentities.firstIndex(of: oldSelectedIdentity)
        {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedRow),
                byExtendingSelection: false
            )
            tableView.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: oldScrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            resetScrollPosition()
        }
    }

    @objc private func tableViewClicked(_ sender: Any?) {
        if NSApp.currentEvent?.clickCount == 2 {
            applySelectedItem()
        }
    }

    private func resetScrollPosition() {
        let clipView = scrollView.contentView

        // Scroll to the top of the content
        clipView.scroll(to: NSPoint(x: 0, y: -SuggestionController.WINDOW_PADDING))

        // Select the first item
        if model?.items.isEmpty == false {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func moveSelection(by offset: Int) {
        let rowCount = tableView.numberOfRows
        guard rowCount > 0 else { return }

        let currentRow = tableView.selectedRow
        let nextRow: Int
        if currentRow < 0 {
            nextRow = offset < 0 ? rowCount - 1 : 0
        } else {
            nextRow = (currentRow + offset % rowCount + rowCount) % rowCount
        }
        tableView.selectRowIndexes(
            IndexSet(integer: nextRow),
            byExtendingSelection: false
        )
        tableView.scrollRowToVisible(nextRow)
    }

    func applySelectedItem() {
        let row = tableView.selectedRow
        guard row >= 0, row < model?.items.count ?? 0 else {
            return
        }
        if let model {
            model.applySelectedItem(item: model.items[tableView.selectedRow])
            windowController?.close()
        }
    }
}

private final class CompletionAppearanceView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}

extension SuggestionViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model?.items.count ?? 0
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model = model,
              row >= 0, row < model.items.count,
              let textView = model.activeTextView else {
            return nil
        }
        return NSHostingView(
            rootView: CodeSuggestionLabelView(
                suggestion: model.items[row],
                labelColor: textView.theme.text.color.resolved(
                    for: tableView.effectiveAppearance
                ),
                secondaryLabelColor: NSColor.secondaryLabelColor.resolved(
                    for: tableView.effectiveAppearance
                ),
                font: textView.font
            )
        )
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        CodeSuggestionRowView {
            let appearance = tableView.effectiveAppearance
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua])
                == .darkAqua
            return NSColor.controlAccentColor
                .resolved(for: appearance)
                .withAlphaComponent(isDark ? 0.32 : 0.18)
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Only allow selection through keyboard navigation or single clicks
        NSApp.currentEvent?.type != .leftMouseDragged
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0 else { return }
        if let model {
            // Update our preview view
            let selectedItem = model.items[tableView.selectedRow]

            previewView.sourcePreview = model.syntaxHighlights(forIndex: tableView.selectedRow)
            previewView.documentation = selectedItem.documentation
            previewView.pathComponents = selectedItem.pathComponents ?? []
            previewView.targetRange = selectedItem.targetPosition
            previewView.hideIfEmpty()
            if !isRestoringSelection {
                model.didSelect(item: selectedItem)
            }
        }
    }
}
