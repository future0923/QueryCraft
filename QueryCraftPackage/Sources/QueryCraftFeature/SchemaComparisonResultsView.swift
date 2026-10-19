import AppKit
import SwiftUI

/// Matches the comparison task: objects above, their definitions/scripts below.
struct SchemaComparisonResultsView: View {
    @Bindable var model: WorkspaceSchemaComparisonModel
    @State private var showsWarnings = false
    @State private var detailMode = 1
    @State private var searchFocusRequest = 0
    private var copy: AppCopy { .current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceGridSearchField(text: $model.search, placeholder: copy.text("查找对象", "Find Objects"),
                    focusRequest: searchFocusRequest, submit: {}, cancel: { model.search = "" },
                    accessibilityIdentifier: "schemaComparisonSearch").frame(width: 260, height: 24)
                Toggle(copy.text("显示一致项", "Show Equal"), isOn: $model.showsEqual).toggleStyle(.checkbox)
                    .accessibilityIdentifier("schemaComparisonShowEqual")
                Spacer()
                if let warnings = model.nativeResult?.warnings, !warnings.isEmpty {
                    Button { showsWarnings.toggle() } label: { Label(copy.text("兼容性提示", "Compatibility Notes"), systemImage: "info.circle") }
                        .popover(isPresented: $showsWarnings) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(copy.text("部署前核对", "Before Deployment")).font(.headline)
                                ForEach(warnings, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                            }.padding(20).frame(width: 380)
                        }
                }
                Button(action: model.selectPlannedChanges) {
                    Label(copy.text("全选", "Select All"), systemImage: "checklist")
                }
                .help(copy.text("选中当前列表中可生成 SQL 的全部变更，并包含必要依赖。", "Select all changes in the current list that support SQL generation, including required dependencies."))
                .disabled(model.phase != .ready || !model.visibleDifferences.contains(where: { $0.sqlForReview != nil }))
                .accessibilityIdentifier("schemaComparisonSelectAdditions")
            }.modifier(SchemaComparisonActionBarStyle()).padding(.horizontal, 16).frame(height: 42)
            SchemaComparisonResultsSplitView {
                SchemaComparisonObjectOutline(differences: model.visibleDifferences, selectedIDs: model.selectedIDs,
                    focusedID: model.focusedID, isEnabled: model.phase == .ready,
                    select: { ids, selected in
                        model.selectChanges(ids, selected: selected)
                    }, focus: { model.focusedID = $0 })

            } detail: {
                VStack(spacing: 0) {
                    HStack {
                        Picker(copy.text("查看方式", "View"), selection: $detailMode) {
                            Text(copy.text("差异详情", "Changes")).tag(0)
                            Text(copy.text("DDL 对比", "DDL Comparison")).tag(1)
                            Text(copy.text("对象 SQL", "Object SQL")).tag(2)
                            Text(copy.text("全部 SQL", "All SQL")).tag(3)
                            Text(copy.text("依赖关系", "Dependencies")).tag(4)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 510)
                            .accessibilityIdentifier("schemaComparisonDetailMode")
                        Spacer()
                        Text(model.focusedDifference?.table ?? "").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).frame(height: 42)
                    Divider()
                    detail
                }
            }
        }
        .background {
            Button("") { searchFocusRequest += 1 }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    @ViewBuilder private var detail: some View {
        if detailMode == 4 {
            List {
                if let groups = model.nativeResult?.batchGroups, !groups.isEmpty {
                    Section(copy.text("批次模式", "Batch Patterns")) {
                        ForEach(groups.keys.sorted(), id: \.self) { pattern in LabeledContent(pattern, value: (groups[pattern] ?? []).joined(separator: ", ")) }
                    }
                }
                if let dependencies = model.nativeResult?.dependencies {
                    ForEach(dependencies.keys.sorted().filter { !(dependencies[$0] ?? []).isEmpty }, id: \.self) { name in
                        LabeledContent(name, value: (dependencies[name] ?? []).sorted().joined(separator: ", "))
                    }
                }
            }.listStyle(.inset).overlay {
                if model.nativeResult?.dependencies.values.allSatisfy({ $0.isEmpty }) != false && model.nativeResult?.batchGroups.isEmpty != false {
                    Text(copy.text("没有对象依赖", "No object dependencies")).foregroundStyle(.secondary)
                }
            }
        } else if detailMode == 0 {
            SchemaComparisonAttributeTable(differences: model.focusedDifferences)
        } else if detailMode == 3 {
            let sql = model.displayScript
            if sql.isEmpty { placeholder(copy.text("选择变更后查看 SQL", "Select changes to review SQL")) }
            else { SchemaComparisonSQLView(ddl: sql) }
        } else if let difference = model.focusedDifference {
            if detailMode == 2 {
                let sql = model.focusedScript
                if !sql.isEmpty { SchemaComparisonSQLView(ddl: sql) }
                else if model.isPlanningFocus { Color.clear.overlay(alignment: .topTrailing) { ProgressView().controlSize(.small).padding(12) } }
                else { placeholder(difference.explanation) }
            } else {
                SchemaComparisonDDLPairView(source: difference.sourceDDL, target: difference.targetDDL,
                    objectID: model.focusedID, sourceDatabase: model.source.database, targetDatabase: model.target.database)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.phase == .loading {
            Color.clear
        } else {
            placeholder(model.errorMessage ?? copy.text("选择对象查看 DDL 对比", "Select an object to compare DDL"))
        }
    }

    private func definition(title: String, database: String, ddl: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text(database).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }.font(.caption).padding(.horizontal, 12).frame(height: 30)
            Divider()
            if ddl.isEmpty { placeholder(copy.text("此端无该对象", "No object on this side")) }
            else { SchemaComparisonSQLView(ddl: ddl) }
        }.clipped()
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// AppKit supplies native outline disclosure, column headers, focus and checkboxes.
private struct SchemaComparisonObjectOutline: NSViewRepresentable {
    let differences: [SchemaComparisonDifference]
    let selectedIDs: Set<String>
    let focusedID: String?
    let isEnabled: Bool
    let select: (Set<String>, Bool) -> Void
    let focus: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let outline = NSOutlineView()
        outline.style = .fullWidth
        outline.rowSizeStyle = .medium
        outline.rowHeight = 27
        outline.usesAlternatingRowBackgroundColors = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsEmptySelection = true
        let copy = AppCopy.current
        for (id, title, width) in [("source", copy.text("源对象", "Source Object"), 380.0),
                                   ("action", copy.text("操作", "Change"), 100.0),
                                   ("target", copy.text("目标对象", "Target Object"), 380.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "action" ? 80 : 200
            column.maxWidth = id == "action" ? 120 : 2000
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.headerView = NSTableHeaderView()
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.setAccessibilityIdentifier("schemaComparisonDifferences")
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let outline = coordinator.outline else { return }
        if coordinator.previous != differences {
            let expanded = Set((0..<outline.numberOfRows).compactMap { row -> String? in
                guard let node = outline.item(atRow: row) as? Node, outline.isItemExpanded(node) else { return nil }
                return node.id
            })
            let firstLoad = coordinator.previous == nil
            coordinator.previous = differences
            coordinator.roots = Node.roots(differences)
            outline.reloadData()
            for root in coordinator.roots {
                outline.expandItem(root)
                for table in root.children {
                    if expanded.contains(table.id) || firstLoad && (differences.count < 100 || table.contains(focusedID)) {
                        outline.expandItem(table)
                    }
                }
            }
        }
        // Updating check state must not rebuild the table or disturb its scroll position.
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? Node else { continue }
            for (column, id) in [(0, "source"), (2, "target")] {
                if let cell = outline.view(atColumn: column, row: row, makeIfNecessary: false) as? Cell {
                    coordinator.configure(cell, node: node, column: id)
                }
            }
        }
        if let focusedID, let node = coordinator.roots.lazy.compactMap({ $0.find(focusedID) }).first {
            let row = outline.row(forItem: node)
            if row >= 0 && outline.selectedRow != row {
                coordinator.synchronizing = true
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                coordinator.synchronizing = false
            }
        }
    }

    @MainActor final class Node: NSObject {
        let id: String
        let source: String
        let target: String
        let status: SchemaComparisonDifference.Status
        let difference: SchemaComparisonDifference?
        let children: [Node]
        let eligible: Set<String>
        let group: Bool
        init(id: String, source: String, target: String = "", status: SchemaComparisonDifference.Status,
             difference: SchemaComparisonDifference? = nil, children: [Node] = [], group: Bool = false) {
            self.id = id; self.source = source; self.target = target; self.status = status
            self.difference = difference; self.children = children; self.group = group
            eligible = difference.map { $0.sqlForReview == nil ? [] : [$0.id] } ?? children.reduce(into: Set<String>()) { $0.formUnion($1.eligible) }
        }
        func contains(_ id: String?) -> Bool { self.id == id || children.contains { $0.contains(id) } }
        func find(_ id: String) -> Node? { self.id == id || difference?.id == id ? self : children.lazy.compactMap { $0.find(id) }.first }
        var firstDifference: SchemaComparisonDifference? { difference ?? children.lazy.compactMap(\.firstDifference).first }
        static func roots(_ differences: [SchemaComparisonDifference]) -> [Node] {
            let copy = AppCopy.current
            let tables = Dictionary(grouping: differences, by: \.groupKey).sorted { $0.key < $1.key }.map { groupKey, changes in
                let name = changes.first?.table ?? ""
                let status: SchemaComparisonDifference.Status
                if changes.contains(where: { $0.status == .unavailable }) { status = .unavailable }
                else if changes.contains(where: { ["table", "view", "function", "sequence", "rule", "owner"].contains($0.object) && $0.status == .added }) { status = .added }
                else if changes.contains(where: { ["table", "view", "function", "sequence", "rule", "owner"].contains($0.object) && $0.status == .targetOnly }) { status = .targetOnly }
                else if changes.allSatisfy({ $0.status == .equal }) { status = .equal }
                else { status = .modified }
                let atomic = changes.count == 1 ? changes.first { ["table", "view", "function", "sequence", "rule", "owner"].contains($0.object) } : nil
                let leaves = atomic == nil ? changes.map { change in
                    Node(id: change.id, source: change.source.isEmpty ? "" : change.attributes.first(where: { $0.key == "name" })?.source ?? change.displayName,
                         target: change.target.isEmpty ? "" : change.attributes.first(where: { $0.key == "name" })?.target ?? change.displayName, status: change.status, difference: change)
                } : []
                return Node(id: groupKey, source: status == .targetOnly ? "" : name,
                            target: status == .added ? "" : name, status: status, difference: atomic, children: leaves)
            }
            return [SchemaComparisonDifference.Status.modified, .added, .targetOnly, .unavailable, .equal].compactMap { status in
                let children = tables.filter { $0.status == status }
                guard !children.isEmpty else { return nil }
                let title: String = switch status {
                case .modified: copy.text("目标需修改", "Modify in Target")
                case .added: copy.text("目标需新增", "Create in Target")
                case .targetOnly: copy.text("目标多余对象", "Remove from Target")
                case .unavailable: copy.text("未完整比较", "Incomplete Objects")
                case .equal: copy.text("无变化", "Unchanged Objects")
                }
                return Node(id: "group:" + status.rawValue, source: title, status: status, children: children, group: true)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: SchemaComparisonObjectOutline
        weak var outline: NSOutlineView?
        var roots: [Node] = []
        var previous: [SchemaComparisonDifference]?
        var synchronizing = false
        init(_ parent: SchemaComparisonObjectOutline) { self.parent = parent }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? roots[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let column = tableColumn?.identifier.rawValue else { return nil }
            let identifier = NSUserInterfaceItemIdentifier(column)
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? Cell ?? Cell()
            cell.identifier = identifier
            configure(cell, node: node, column: column)
            return cell
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? Node)?.group == true ? 36 : 28
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            let row = NSTableRowView()
            if (item as? Node)?.group == true { row.backgroundColor = .separatorColor.withAlphaComponent(0.12) }
            return row
        }
        func configure(_ cell: Cell, node: Node, column: String) {
            let copy = AppCopy.current
            let operation = node.difference?.operationTitle ?? {
                switch node.status {
                case .modified: return copy.text("修改", "Modify")
                case .added: return copy.text("新增", "Create")
                case .targetOnly: return copy.text("删除", "Remove")
                case .unavailable: return copy.text("未完成", "Incomplete")
                case .equal: return copy.text("一致", "Equal")
                }
            }()
            cell.label.stringValue = column == "source" ? node.source : column == "target" ? node.target : node.group ? "" : operation
            let isObject = !node.group && (node.difference == nil || node.difference?.object == "table" || node.difference?.object == "view" || node.difference?.object == "function")
            cell.label.font = .systemFont(ofSize: 12, weight: node.group || isObject ? .semibold : .regular)
            let selected = node.eligible.intersection(parent.selectedIDs).count
            if node.group && column == "source" {
                cell.count.stringValue = copy.text("\(node.children.count) 个对象 · 已选 \(selected)/\(node.eligible.count) 项", "\(node.children.count) objects · \(selected)/\(node.eligible.count) changes selected")
            } else if !node.children.isEmpty && column == (node.source.isEmpty ? "target" : "source") {
                cell.count.stringValue = "\(selected)/\(node.eligible.count)"
            } else { cell.count.stringValue = "" }
            cell.count.isHidden = cell.count.stringValue.isEmpty
            let name = column == "source" ? node.source : column == "target" ? node.target : ""
            cell.symbol.isHidden = node.group ? column != "source" : column != "action" && name.isEmpty
            let operationSymbol: String = switch node.status {
            case .added: "plus.circle"
            case .modified: "arrow.left.arrow.right"
            case .targetOnly: "minus.circle"
            case .equal: "equal.circle"
            case .unavailable: "exclamationmark.triangle"
            }
            cell.symbol.image = NSImage(systemSymbolName: column == "action" || node.group ? operationSymbol : node.difference?.kindSymbol ?? "tablecells", accessibilityDescription: nil)
            let tint: NSColor = switch node.status {
            case .added: .systemGreen
            case .modified: .systemBlue
            case .targetOnly: .systemRed
            case .unavailable: .systemOrange
            case .equal: .secondaryLabelColor
            }
            cell.symbol.contentTintColor = column == "action" || node.group ? tint : .secondaryLabelColor
            cell.label.textColor = column == "action" ? tint : .labelColor
            let deletesName = !node.group && column == "target" && node.status == .targetOnly
            cell.label.attributedStringValue = NSAttributedString(string: cell.label.stringValue, attributes: [
                .font: cell.label.font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: deletesName ? NSColor.systemRed : cell.label.textColor ?? .labelColor,
                .strikethroughStyle: deletesName ? NSUnderlineStyle.single.rawValue : 0
            ])
            let checkColumn = node.status == .targetOnly && !node.group ? "target" : "source"
            cell.check.isHidden = column != checkColumn || node.eligible.isEmpty
            cell.check.isEnabled = parent.isEnabled
            cell.check.state = node.eligible.isSubset(of: parent.selectedIDs) ? .on : node.eligible.isDisjoint(with: parent.selectedIDs) ? .off : .mixed
            cell.onCheck = { [weak self] state in self?.parent.select(node.eligible, state) }
            cell.check.setAccessibilityLabel(node.source.isEmpty ? node.target : node.source)
            cell.label.toolTip = node.difference.map { $0.changeSummary + "\n" + $0.explanation } ?? cell.label.stringValue
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, let outline, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
            let id = node.group ? nil : node.difference?.id ?? node.id
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.roots.contains(where: { $0.contains(node.id) }) else { return }
                self.parent.focus(id)
            }
        }
    }

    @MainActor final class Cell: NSTableCellView {
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let label = NSTextField(labelWithString: "")
        let count = NSTextField(labelWithString: "")
        let symbol = NSImageView()
        var onCheck: ((Bool) -> Void)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            check.allowsMixedState = true
            check.target = self; check.action = #selector(changed)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            symbol.setContentHuggingPriority(.required, for: .horizontal)
            count.font = .systemFont(ofSize: 11)
            count.textColor = .secondaryLabelColor
            count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [check, symbol, label, count])
            stack.spacing = 6; stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        @objc private func changed() { onCheck?(check.state != .off) }
    }
}
