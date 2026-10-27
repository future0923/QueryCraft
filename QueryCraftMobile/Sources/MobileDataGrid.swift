import SwiftUI
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobileGridCellAddress: Hashable, Sendable { let row: Int; let column: Int }

struct MobileGridData: Sendable {
    var pendingCells: Set<MobileGridCellAddress> = []
    var deletedRows: Set<Int> = []
    let columns: [String]
    let details: [String]
    let rows: [[String?]]
    let cells: [[WorkspaceDatabaseDataCell]]
    let metadata: [WorkspaceDatabaseDataColumn]

    init(preview: MobileSQLPreview?, details: [String]? = nil) {
        columns = preview?.result.columns ?? []
        self.details = details ?? preview?.columnDetails ?? preview?.result.columnTypes.map { $0 ?? "" } ?? []
        rows = preview?.result.rows ?? []
        cells = preview?.cells ?? []
        metadata = preview?.workspaceColumns ?? []
    }

    init(columns: [String], rows: [[String?]]) {
        self.columns = columns; details = []; self.rows = rows; cells = []
        metadata = columns.enumerated().map { .init(id: $0.offset, name: $0.element) }
    }

    init(esColumns columns: [WorkspaceDatabaseDataColumn], rows: [WorkspaceDatabaseDataRow]) {
        self.columns = columns.map(\.name); details = columns.map { $0.type ?? "" }; metadata = columns
        cells = rows.map(\.values)
        self.rows = rows.map { $0.values.map { value in if case .text(let text) = value { return text }; return nil } }
    }

    func cell(row: Int, column: Int) -> WorkspaceDatabaseDataCell {
        guard rows.indices.contains(row) else { return .null }
        if cells.indices.contains(row), cells[row].indices.contains(column) { return cells[row][column] }
        guard rows[row].indices.contains(column), let value = rows[row][column] else { return .null }
        return .text(value)
    }
}

/// Two dimensional reuse: only cells inside the visible rectangle are materialized.
struct MobileDataGrid: UIViewRepresentable {
    var preferences: MobilePreferences = .shared
    let data: MobileGridData
    let revision: String
    let widthKey: String
    var viewport: MobileGridViewport? = nil
    var restorationID: UUID? = nil
    var tracksViewport = true
    var viewportOwner: UUID? = nil
    var cellAccessibilityHint = "轻点查看单元格"
    var searchController: WorkspaceGridSearchController? = nil
    var revealsMatchOnResize = false
    var timestampScope: String? = nil
    var pageContext: MobileGridPageContext? = nil
    var pendingChangeCount = 0
    var onShowPendingChanges: (() -> Void)? = nil
    var onInspect: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView { Self.makeCollectionView(coordinator: context.coordinator) }

    @MainActor static func makeCollectionView(coordinator: Coordinator) -> UICollectionView {
        let layout = MobileGridLayout()
        let view = MobileGridCollectionView(frame: .zero, collectionViewLayout: layout)
        view.didResize = { [weak coordinator, weak view] in
            guard let coordinator, let view, !coordinator.isApplying,
                  coordinator.parent.revealsMatchOnResize,
                  let search = coordinator.parent.searchController, search.isPresented, !search.isSearching,
                  let index = search.currentMatchIndex, search.matches.indices.contains(index) else { return }
            let match = search.matches[index]
            guard view.indexPathsForSelectedItems?.contains(IndexPath(item: match.dataColumnIndex, section: match.rowIndex + 1)) == true else { return }
            coordinator.reveal(match, in: view)
        }
        view.backgroundColor = .systemBackground
        view.alwaysBounceVertical = true
        view.isDirectionalLockEnabled = true
        view.keyboardDismissMode = .onDrag
        view.dataSource = coordinator; view.delegate = coordinator
        view.panGestureRecognizer.addTarget(coordinator, action: #selector(Coordinator.panStateChanged(_:)))
        view.register(MobileGridCell.self, forCellWithReuseIdentifier: "cell")
        view.accessibilityIdentifier = "databaseGrid"
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        apply(to: view, coordinator: context.coordinator)
    }

    @MainActor func apply(to view: UICollectionView, coordinator: Coordinator) {
        let style = preferences.gridStyle
        let styleChanged = coordinator.style != style
        coordinator.style = style
        coordinator.parent = self
        defer { coordinator.attachSearch(to: view) }
        let timestampChanged = tracksViewport && viewport?.activeOwner == viewportOwner
            ? coordinator.timestampDisplay.configure(scope: timestampScope ?? widthKey, columns: data.metadata) : false
        let restoring = coordinator.revision.isEmpty || coordinator.restorationID != restorationID
        let changesPage = coordinator.pageContext != pageContext
        guard coordinator.revision != revision || restoring || timestampChanged || changesPage || styleChanged else { return }
        coordinator.isApplying = true
        defer { coordinator.isApplying = false; coordinator.saveViewport(view) }
        let sameShape = coordinator.columns == data.columns && coordinator.metadata == data.metadata
        let sameObject = sameShape && coordinator.widthKey == widthKey
        let sameContext = sameObject && !changesPage
        if restoring || !sameContext { coordinator.axisLock.end() }
        let restored = restoring && viewport?.context == widthKey && viewport?.metadata == data.metadata && viewport?.pageContext == pageContext ? viewport : nil
        let oldOffset = restored?.offset ?? (sameObject ? CGPoint(x: view.contentOffset.x, y: changesPage ? 0 : view.contentOffset.y) : .zero)
        let selected = restored != nil ? restored?.selection : (sameContext ? view.indexPathsForSelectedItems?.first : nil)
        coordinator.restorationID = restorationID
        coordinator.revision = revision
        coordinator.pageContext = pageContext
        if !sameShape || coordinator.widthKey != widthKey || timestampChanged || styleChanged || (!coordinator.hasSizedRows && !data.rows.isEmpty) {
            coordinator.widthKey = widthKey
            coordinator.columns = data.columns
            coordinator.metadata = data.metadata
            coordinator.widths = coordinator.automaticWidths()
            coordinator.hasSizedRows = !data.rows.isEmpty
        }
        if let restored, restored.widths.count == data.columns.count,
           restored.widths.allSatisfy({ $0.isFinite && $0 >= 60 && $0 <= 960 }) {
            coordinator.widths = restored.widths
        }
        (view.collectionViewLayout as? MobileGridLayout)?.widths = coordinator.widths
        (view.collectionViewLayout as? MobileGridLayout)?.rowCount = data.rows.count
        view.reloadData()
        view.layoutIfNeeded()
        if let selected, selected.section > 0, selected.section <= data.rows.count, data.columns.indices.contains(selected.item) {
            view.selectItem(at: selected, animated: false, scrollPosition: [])
        } else {
            for path in view.indexPathsForSelectedItems ?? [] { view.deselectItem(at: path, animated: false) }
        }
        view.contentOffset = CGPoint(x: min(max(0, oldOffset.x), max(0, view.contentSize.width - view.bounds.width)),
            y: min(max(0, oldOffset.y), max(0, view.contentSize.height - view.bounds.height)))
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: MobileDataGrid
        var revision = "", widthKey = ""
        var columns: [String] = []
        var metadata: [WorkspaceDatabaseDataColumn] = []
        var pageContext: MobileGridPageContext?
        var hasSizedRows = false
        var widths: [CGFloat] = []
        var restorationID: UUID?
        var isApplying = false
        var style: MobileGridStyle?
        var axisLock = MobileGridAxisLock()
        weak var attachedSearchController: WorkspaceGridSearchController?
        private let localTimestampDisplay = MobileGridTimestampDisplay()
        var timestampDisplay: MobileGridTimestampDisplay { parent.viewport?.timestampDisplay ?? localTimestampDisplay }
        init(_ parent: MobileDataGrid) { self.parent = parent }
        func attachSearch(to view: UICollectionView) {
            guard let search = parent.searchController, attachedSearchController !== search else { return }
            attachedSearchController = search
            search.attachSelectionHandler { [weak self, weak view] match in
                guard let self, let view else { return }
                self.reveal(match, in: view)
            }
        }
        func reveal(_ match: WorkspaceGridSearchMatch, in view: UICollectionView) {
            guard parent.tracksViewport, parent.viewport?.activeOwner == parent.viewportOwner,
                  parent.data.rows.indices.contains(match.rowIndex),
                  parent.data.columns.indices.contains(match.dataColumnIndex) else { return }
            axisLock.end()
            view.setContentOffset(view.contentOffset, animated: false)
            let path = IndexPath(item: match.dataColumnIndex, section: match.rowIndex + 1)
            guard let cell = view.collectionViewLayout.layoutAttributesForItem(at: path) else { return }
            let headerHeight = view.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.height ?? 0
            var offset = view.contentOffset
            if cell.frame.minX < offset.x || cell.frame.width > view.bounds.width { offset.x = cell.frame.minX }
            else if cell.frame.maxX > offset.x + view.bounds.width { offset.x = cell.frame.maxX - view.bounds.width }
            if cell.frame.minY < offset.y + headerHeight { offset.y = cell.frame.minY - headerHeight }
            else if cell.frame.maxY > offset.y + view.bounds.height { offset.y = cell.frame.maxY - view.bounds.height }
            offset.x = min(max(0, offset.x), max(0, view.contentSize.width - view.bounds.width))
            offset.y = min(max(0, offset.y), max(0, view.contentSize.height - view.bounds.height))
            view.selectItem(at: path, animated: false, scrollPosition: [])
            view.setContentOffset(offset, animated: false)
            saveViewport(view)
        }
        func numberOfSections(in collectionView: UICollectionView) -> Int { parent.data.rows.count + 1 }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { parent.data.columns.count }
        func collectionView(_ view: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "cell", for: path) as! MobileGridCell
            let column = path.item
            let header = path.section == 0
            if header {
                cell.label.text = parent.data.columns[column]
                cell.subtitle.text = parent.preferences.showsColumnDetails && parent.data.details.indices.contains(column) ? parent.data.details[column] : ""
                cell.label.font = .systemFont(ofSize: parent.preferences.dataGridFontSize, weight: .semibold)
                cell.label.textColor = .label
                cell.backgroundColor = .secondarySystemBackground
                cell.resize = { [weak self, weak view] delta in
                    guard let self, let view else { return }
                    self.widths[column] = max(60, min(960, self.widths[column] + delta))
                    (view.collectionViewLayout as? MobileGridLayout)?.widths = self.widths
                    view.collectionViewLayout.invalidateLayout()
                    let saved = Dictionary(uniqueKeysWithValues: self.parent.data.columns.enumerated().map {
                        ("\($0.offset):\($0.element)", Double(self.widths[$0.offset]))
                    })
                    UserDefaults.standard.set(saved, forKey: "gridWidths." + self.parent.widthKey)
                    self.saveViewport(view)
                }
            } else {
                let value = parent.data.cell(row: path.section - 1, column: column)
                cell.label.text = timestampDisplay.preview(value, column: column, maximumCharacterCount: 200, style: style)
                    .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                cell.label.font = parent.preferences.gridStyle.font
                cell.label.textColor = value == .null ? .secondaryLabel : .label
                cell.subtitle.text = ""
                cell.backgroundColor = (parent.preferences.usesAlternatingTableRows && path.section % 2 == 0) ? .secondarySystemBackground.withAlphaComponent(0.45) : .systemBackground
                if parent.data.deletedRows.contains(path.section - 1) {
                    cell.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
                } else if parent.data.pendingCells.contains(.init(row: path.section - 1, column: column)) {
                    cell.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.2)
                }
                cell.resize = nil
            }
            cell.grip.isHidden = !header
            cell.accessibilityLabel = header ? cell.label.text : "\(parent.data.columns[column])，\(cell.label.text ?? "")"
            if !header, parent.data.deletedRows.contains(path.section - 1) { cell.accessibilityLabel = (cell.accessibilityLabel ?? "") + "，待删除" }
            else if !header, parent.data.pendingCells.contains(.init(row: path.section - 1, column: column)) {
                cell.accessibilityLabel = (cell.accessibilityLabel ?? "") + "，待提交"
            }
            cell.accessibilityHint = header ? "长按设置显示格式，拖动右侧边缘调整列宽" : parent.cellAccessibilityHint
            cell.accessibilityCustomActions = header ? WorkspaceTimestampDisplayMode.allCases.map { mode in
                let context = parent.widthKey, metadata = parent.data.metadata, scope = parent.timestampScope
                return UIAccessibilityCustomAction(name: mode.title) { [weak self, weak view] _ in
                    guard let self, let view, self.parent.widthKey == context, self.parent.data.metadata == metadata, self.parent.timestampScope == scope else { return false }
                    self.setTimestampMode(mode, column: column, in: view)
                    return true
                }
            } : (parent.pendingChangeCount > 0 && parent.onShowPendingChanges != nil ? [UIAccessibilityCustomAction(name: "查看待提交改动") { [weak self] _ in
                guard let self, self.parent.pendingChangeCount > 0 else { return false }
                self.parent.onShowPendingChanges?(); return true
            }] : nil)
            return cell
        }
        func collectionView(_ view: UICollectionView, contextMenuConfigurationForItemAt path: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
            if path.section > 0 {
                guard parent.pendingChangeCount > 0, parent.onShowPendingChanges != nil else { return nil }
                let context = parent.widthKey, revision = parent.revision
                return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                    guard let self, self.parent.widthKey == context, self.parent.revision == revision else { return nil }
                    return UIMenu(children: [UIAction(title: "待提交改动（\(self.parent.pendingChangeCount)）", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                        guard let self, self.parent.widthKey == context, self.parent.revision == revision else { return }
                        self.parent.onShowPendingChanges?()
                    }])
                }
            }
            guard parent.data.metadata.indices.contains(path.item) else { return nil }
            let context = parent.widthKey, metadata = parent.data.metadata, scope = parent.timestampScope
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self, weak view] _ in
                guard let self, let view, self.parent.widthKey == context, self.parent.data.metadata == metadata, self.parent.timestampScope == scope else { return nil }
                return UIMenu(title: "显示格式 · \(metadata[path.item].name)", children: WorkspaceTimestampDisplayMode.allCases.map { mode in
                    UIAction(title: mode.title, state: self.timestampDisplay.mode(column: path.item) == mode ? .on : .off) { [weak self, weak view] _ in
                        guard let self, let view, self.parent.widthKey == context, self.parent.data.metadata == metadata, self.parent.timestampScope == scope else { return }
                        self.setTimestampMode(mode, column: path.item, in: view)
                    }
                })
            }
        }
        func setTimestampMode(_ mode: WorkspaceTimestampDisplayMode, column: Int, in view: UICollectionView) {
            guard parent.tracksViewport, parent.viewport?.activeOwner == parent.viewportOwner,
                  widths.indices.contains(column),
                  timestampDisplay.set(mode, column: column) else { return }
            // Match Mac's per-column format action: resize this column only.
            axisLock.end()
            isApplying = true
            defer { isApplying = false; saveViewport(view) }
            let offset = view.contentOffset
            widths[column] = automaticWidths(ignoringSavedColumn: column)[column]
            (view.collectionViewLayout as? MobileGridLayout)?.widths = widths
            view.layoutIfNeeded()
            view.contentOffset = CGPoint(x: min(offset.x, max(0, view.contentSize.width - view.bounds.width)), y: offset.y)
            let paths = view.indexPathsForVisibleItems.filter { $0.item == column && $0.section > 0 }
            view.reconfigureItems(at: paths)
        }
        func collectionView(_ view: UICollectionView, didSelectItemAt path: IndexPath) {
            guard path.section > 0 else { return }
            saveViewport(view)
            parent.onInspect(path.section - 1, path.item)
        }
        func saveViewport(_ view: UIScrollView) {
            guard parent.tracksViewport, let state = parent.viewport, state.activeOwner == parent.viewportOwner else { return }
            state.context = parent.widthKey; state.columns = parent.data.columns
            state.metadata = parent.data.metadata; state.pageContext = parent.pageContext
            state.offset = view.contentOffset; state.widths = widths
            state.selection = (view as? UICollectionView)?.indexPathsForSelectedItems?.first
        }
        func scrollViewWillBeginDragging(_ view: UIScrollView) {
            axisLock.begin(at: view.contentOffset, translation: view.panGestureRecognizer.translation(in: view),
                           velocity: view.panGestureRecognizer.velocity(in: view))
        }
        func scrollViewDidScroll(_ view: UIScrollView) {
            guard !isApplying else { return }
            if axisLock.isTracking {
                let offset = axisLock.constrain(view.contentOffset, translation: view.panGestureRecognizer.translation(in: view),
                                                velocity: view.panGestureRecognizer.velocity(in: view))
                if view.contentOffset != offset { view.contentOffset = offset }
            }
            saveViewport(view)
        }
        func scrollViewWillEndDragging(_ view: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            targetContentOffset.pointee = axisLock.constrain(targetContentOffset.pointee, velocity: velocity)
        }
        func scrollViewDidEndDragging(_ view: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { axisLock.end() }
            saveViewport(view)
        }
        func scrollViewDidEndDecelerating(_ view: UIScrollView) { axisLock.end(); saveViewport(view) }
        func scrollViewDidEndScrollingAnimation(_ view: UIScrollView) { axisLock.end(); saveViewport(view) }
        func scrollViewShouldScrollToTop(_ view: UIScrollView) -> Bool { axisLock.end(); return true }
        @objc func panStateChanged(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .cancelled || recognizer.state == .failed { axisLock.end() }
        }
        func automaticWidths(ignoringSavedColumn: Int? = nil) -> [CGFloat] {
            let samples = WorkspaceGridSampling.sampleIndexes(rowCount: parent.data.rows.count, columnCount: parent.data.columns.count)
            let saved = UserDefaults.standard.dictionary(forKey: "gridWidths." + parent.widthKey) ?? [:]
            let attributes: [NSAttributedString.Key: Any] = [.font: parent.preferences.gridStyle.font]
            return parent.data.columns.enumerated().map { column, name in
                if column != ignoringSavedColumn, let width = saved["\(column):\(name)"] as? Double, width.isFinite { return max(60, min(960, width)) }
                var texts = [WorkspaceDatabaseDataCell.boundedPreview(name, maximumCharacterCount: 50)]
                if parent.preferences.showsColumnDetails, parent.data.details.indices.contains(column) { texts.append(String(parent.data.details[column].prefix(50))) }
                let mode = timestampDisplay.mode(column: column)
                if mode == .seconds || mode == .milliseconds || (mode == .automatic && parent.preferences.formatsTimestamps && parent.data.metadata.indices.contains(column)
                    && WorkspaceTimestampDisplayFormatter.hasTimestampHint(parent.data.metadata[column])) {
                    texts.append("2000-01-01 00:00:00")
                }
                texts += samples.map { timestampDisplay.preview(parent.data.cell(row: $0, column: column), column: column, maximumCharacterCount: WorkspaceGridSampling.maximumMeasuredCharacters, style: parent.preferences.gridStyle) }
                let width = texts.map { ($0 as NSString).size(withAttributes: attributes).width + 24 }.max() ?? 100
                return min(WorkspaceGridSampling.maximumAutomaticColumnWidth, max(96, ceil(width)))
            }
        }
    }
}

@MainActor private final class MobileGridCollectionView: UICollectionView {
    var didResize: (() -> Void)?
    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        didResize?()
    }
}

@MainActor private final class MobileGridCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    let label = UILabel(), subtitle = UILabel(), grip = UIView()
    private var resizePan: UIPanGestureRecognizer?
    var resize: ((CGFloat) -> Void)? { didSet { resizePan?.isEnabled = resize != nil } }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        let selection = UIView(); selection.backgroundColor = MobileAppearance.selectionColor
        selectedBackgroundView = selection
        label.numberOfLines = 1; label.lineBreakMode = .byTruncatingTail
        subtitle.font = .monospacedSystemFont(ofSize: 11, weight: .regular); subtitle.textColor = .secondaryLabel
        contentView.addSubview(label); contentView.addSubview(subtitle)
        grip.backgroundColor = .separator; contentView.addSubview(grip)
        // A generous touch target extends inward from the visible divider.
        let target = UIView(); target.backgroundColor = .clear; contentView.addSubview(target)
        target.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([target.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), target.topAnchor.constraint(equalTo: contentView.topAnchor), target.bottomAnchor.constraint(equalTo: contentView.bottomAnchor), target.widthAnchor.constraint(equalToConstant: 24)])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        pan.delegate = self; pan.isEnabled = false; resizePan = pan
        target.addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let hasSubtitle = !(subtitle.text ?? "").isEmpty
        label.frame = CGRect(x: 10, y: hasSubtitle ? 7 : 0, width: max(0, bounds.width - 24), height: hasSubtitle ? 22 : bounds.height)
        subtitle.frame = CGRect(x: 10, y: 31, width: max(0, bounds.width - 24), height: 15)
        grip.frame = CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        contentView.layer.borderWidth = 0.25; contentView.layer.borderColor = UIColor.separator.cgColor
    }
    @objc private func pan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        resize?(recognizer.translation(in: self).x); recognizer.setTranslation(.zero, in: self)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === resizePan, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = pan.velocity(in: self)
        return resize != nil && abs(velocity.x) > abs(velocity.y)
    }
}

@MainActor final class MobileGridLayout: UICollectionViewLayout {
    var widths: [CGFloat] = [] { didSet { rebuildOffsets() } }
    var rowCount = 0
    private var offsets: [CGFloat] = [0]
    private let rowHeight: CGFloat = 44, headerHeight: CGFloat = 54
    private func rebuildOffsets() { offsets = [0]; for width in widths { offsets.append((offsets.last ?? 0) + width) } }
    override var collectionViewContentSize: CGSize { CGSize(width: offsets.last ?? 0, height: headerHeight + CGFloat(rowCount) * rowHeight) }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }
    override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard widths.indices.contains(path.item), path.section <= rowCount else { return nil }
        let value = UICollectionViewLayoutAttributes(forCellWith: path)
        let header = path.section == 0
        value.frame = CGRect(x: offsets[path.item], y: header ? max(0, collectionView?.contentOffset.y ?? 0) : headerHeight + CGFloat(path.section - 1) * rowHeight,
                             width: widths[path.item], height: header ? headerHeight : rowHeight)
        value.zIndex = header ? 10 : 0
        return value
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !widths.isEmpty else { return [] }
        // Binary search the first intersecting column; no work proportional to total cells.
        var low = 0, high = widths.count
        while low < high { let mid = (low + high) / 2; if offsets[mid + 1] < rect.minX { low = mid + 1 } else { high = mid } }
        var columns: [Int] = [], column = low
        while column < widths.count, offsets[column] <= rect.maxX { columns.append(column); column += 1 }
        let first = max(1, Int(floor((rect.minY - headerHeight) / rowHeight)) + 1)
        let last = min(rowCount, Int(ceil((rect.maxY - headerHeight) / rowHeight)) + 1)
        var result = columns.compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
        if first <= last {
            for row in first...last { result += columns.compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: row)) } }
        }
        return result
    }
}
