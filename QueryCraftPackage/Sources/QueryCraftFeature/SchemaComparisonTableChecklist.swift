import AppKit
import SwiftUI

/// Native checkboxes keep table scope keyboard- and VoiceOver-accessible.
struct SchemaComparisonTableChecklist: NSViewRepresentable {
    let names: [String]
    let selected: Set<String>
    let isEnabled: Bool
    let toggle: (String, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 600
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setAccessibilityIdentifier("schemaComparisonTables")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        if context.coordinator.names != names {
            context.coordinator.names = names
            table.reloadData()
        }
        for row in 0..<table.numberOfRows {
            if let button = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSButton {
                context.coordinator.configure(button, row: row)
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SchemaComparisonTableChecklist
        var names: [String] = []
        init(_ parent: SchemaComparisonTableChecklist) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { names.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("tableScope")
            let button = tableView.makeView(withIdentifier: id, owner: nil) as? NSButton
                ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(changed(_:)))
            button.identifier = id
            button.target = self
            button.action = #selector(changed(_:))
            configure(button, row: row)
            return button
        }
        func configure(_ button: NSButton, row: Int) {
            let name = names[row]
            button.title = name
            button.tag = row
            button.state = parent.selected.contains(name) ? .on : .off
            button.isEnabled = parent.isEnabled
            button.cell?.lineBreakMode = .byTruncatingMiddle
            button.toolTip = name
            button.setAccessibilityIdentifier("schemaComparisonTable:" + name)
            button.setAccessibilityLabel(name)
        }
        @objc func changed(_ button: NSButton) {
            guard names.indices.contains(button.tag) else { return }
            parent.toggle(names[button.tag], button.state == .on)
        }
    }
}
