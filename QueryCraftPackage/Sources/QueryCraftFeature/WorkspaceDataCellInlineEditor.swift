import AppKit

@MainActor
final class WorkspaceDataCellInlineEditor: NSObject, NSTextFieldDelegate {
    private weak var tableView: WorkspaceDirectDrawTableView?
    private weak var editor: NSTextField?
    private var context: WorkspaceDatabaseDataCellInlineEditContext?
    private var tableColumnIndex: Int?
    private var text = ""
    private var initialText = ""
    private var isEnding = false
    private var update: ((WorkspaceDatabaseDataCellInlineEditContext,
        WorkspaceDatabaseInspectorMutation) -> Void)?
    private var canEdit: ((Int, Int) -> Bool)?
    private var beginEdit: ((Int, Int) -> Void)?
    private var redraw: ((Int) -> Void)?

    var isEditing: Bool { editor != nil }
    var editingRowIndex: Int? { context?.rowIndex }

    func begin(
        in tableView: WorkspaceDirectDrawTableView,
        context: WorkspaceDatabaseDataCellInlineEditContext,
        tableColumnIndex: Int,
        cellFont: NSFont,
        replacingWith replacement: String? = nil,
        update: @escaping (
            WorkspaceDatabaseDataCellInlineEditContext,
            WorkspaceDatabaseInspectorMutation
        ) -> Void,
        canEdit: @escaping (Int, Int) -> Bool,
        beginEdit: @escaping (Int, Int) -> Void,
        redraw: @escaping (Int) -> Void
    ) {
        finish(commit: true)
        if let lifetime = context.editingLifetime {
            guard let revision = context.editingRevision,
                  lifetime.register(revision: revision, endEditing: { [weak self] commit in
                      if !commit { self?.update = nil }
                      self?.finish(commit: commit)
                  }) else { return }
        }
        guard context.rowIndex >= 0,
              context.rowIndex < tableView.numberOfRows,
              tableView.tableColumns.indices.contains(tableColumnIndex)
        else {
            NSSound.beep()
            return
        }

        self.tableView = tableView
        self.context = context
        self.tableColumnIndex = tableColumnIndex
        self.update = update
        self.canEdit = canEdit
        self.beginEdit = beginEdit
        self.redraw = redraw

        tableView.selectRowIndexes(
            IndexSet(integer: context.rowIndex),
            byExtendingSelection: false
        )
        let editor = NSTextField()
        editor.stringValue = replacement ?? context.initialText
        if let placeholderText = context.placeholderText {
            editor.placeholderAttributedString = NSAttributedString(
                string: placeholderText,
                attributes: [
                    .foregroundColor: NSColor.placeholderTextColor,
                    .font: NSFontManager.shared.convert(
                        cellFont,
                        toHaveTrait: .italicFontMask
                    ),
                ]
            )
        }
        editor.font = cellFont
        editor.isEditable = true
        editor.isSelectable = true
        editor.isBordered = false
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.focusRingType = .none
        editor.wantsLayer = true
        editor.layer?.borderColor = NSColor.controlAccentColor.cgColor
        editor.layer?.borderWidth = 2
        editor.lineBreakMode = .byTruncatingTail
        editor.delegate = self
        editor.setAccessibilityLabel(
            AppCopy.current.text(
                "编辑行，\(context.columnName)",
                "Edit row, \(context.columnName)"
            )
        )
        editor.setAccessibilityIdentifier("dataCellInlineEditor")
        self.editor = editor
        text = editor.stringValue
        initialText = context.initialText
        tableView.addSubview(editor, positioned: .above, relativeTo: nil)
        layout()

        if let replacement {
            update(context, .value(replacement))
        }
        Task { @MainActor [weak self, weak editor] in
            await Task.yield()
            guard let self, let editor, self.editor === editor,
                  editor.superview === tableView else { return }
            tableView.addSubview(editor, positioned: .above, relativeTo: nil)
            self.layout()
            guard tableView.window?.makeFirstResponder(editor) == true else {
                return
            }
            (editor.currentEditor() as? NSTextView)?.insertionPointColor =
                .controlAccentColor
            editor.currentEditor()?.moveToEndOfDocument(nil)
        }
    }

    func layout() {
        guard let tableView, let editor, let context, let tableColumnIndex else {
            return
        }
        editor.frame = tableView.frameOfCell(
            atColumn: tableColumnIndex,
            row: context.rowIndex
        ).insetBy(dx: 1, dy: 1)
    }

    func finish(
        commit: Bool,
        movingBy offset: Int? = nil,
        restoresTableFocus: Bool = true
    ) {
        guard !isEnding, let editor, let context else { return }
        isEnding = true
        let currentColumn = tableColumnIndex
        if commit {
            text = editor.currentEditor()?.string ?? editor.stringValue
            if text != initialText { update?(context, .value(text)) }
        } else {
            update?(context, context.initialMutation)
        }
        editor.delegate = nil
        context.editingLifetime?.unregister(revision: context.editingRevision)
        editor.removeFromSuperview()
        self.editor = nil
        self.context = nil
        tableColumnIndex = nil
        text = ""
        initialText = ""
        if restoresTableFocus {
            tableView?.window?.makeFirstResponder(tableView)
        }
        redraw?(context.rowIndex)
        isEnding = false

        guard let offset, let currentColumn,
              let targetColumn = adjacentColumn(
                  row: context.rowIndex,
                  from: currentColumn,
                  offset: offset
              ) else { return }
        selectAndBegin(row: context.rowIndex, column: targetColumn)
    }

    func cancel() { finish(commit: false) }

    private func moveVertically(by offset: Int) {
        guard offset != 0, let context, let column = tableColumnIndex,
              let tableView else { return }
        let row = context.rowIndex + offset
        guard row >= 0, row < tableView.numberOfRows,
              canEdit?(row, column) == true else {
            NSSound.beep()
            return
        }
        finish(commit: true)
        selectAndBegin(row: row, column: column)
    }

    private func adjacentColumn(row: Int, from current: Int, offset: Int) -> Int? {
        guard let tableView else { return nil }
        let editable = tableView.tableColumns.indices.filter {
            canEdit?(row, $0) == true
        }
        guard let position = editable.firstIndex(of: current),
              !editable.isEmpty else { return nil }
        return editable[(position + offset + editable.count) % editable.count]
    }

    private func selectAndBegin(row: Int, column: Int) {
        guard let tableView else { return }
        let coordinate = WorkspaceGridCoordinate(row: row, column: column)
        tableView.selectGridRange(anchor: coordinate, active: coordinate)
        tableView.scrollRowToVisible(row)
        tableView.scrollColumnToVisible(column)
        beginEdit?(row, column)
    }

    nonisolated func controlTextDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let editor, let context else { return }
            let current = editor.currentEditor()?.string ?? editor.stringValue
            guard current != text else { return }
            text = current
            update?(context, .value(current))
        }
    }

    nonisolated func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        MainActor.assumeIsolated {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                finish(commit: false)
            case #selector(NSResponder.insertNewline(_:)):
                text = textView.string
                let usesCommand = NSApp.currentEvent?.modifierFlags
                    .contains(.command) == true
                finish(commit: true, movingBy: usesCommand ? nil : 1)
            case #selector(NSResponder.insertTab(_:)):
                text = textView.string
                finish(commit: true, movingBy: 1)
            case #selector(NSResponder.insertBacktab(_:)):
                text = textView.string
                finish(commit: true, movingBy: -1)
            case #selector(NSResponder.moveUp(_:)):
                text = textView.string
                moveVertically(by: -1)
            case #selector(NSResponder.moveDown(_:)):
                text = textView.string
                moveVertically(by: 1)
            default:
                return false
            }
            return true
        }
    }

    nonisolated func controlTextDidEndEditing(_ notification: Notification) {
        MainActor.assumeIsolated {
            finish(commit: true, restoresTableFocus: false)
        }
    }
}
