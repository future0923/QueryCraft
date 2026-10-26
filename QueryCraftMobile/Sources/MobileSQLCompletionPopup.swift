import UIKit

/// Uses the editor's window and visible caret, including Stage Manager bounds.
enum MobileSQLCompletionLayout {
    static let rowHeight: CGFloat = 64

    static func frame(in bounds: CGRect, editor: CGRect, caret: CGRect, keyboard: CGRect?, count: Int) -> CGRect? {
        guard count > 0, bounds.intersects(caret), editor.intersects(caret) else { return nil }
        let canvas = bounds.insetBy(dx: 8, dy: 8)
        let column = CGRect(x: max(canvas.minX, editor.minX), y: canvas.minY,
                            width: min(canvas.maxX, editor.maxX) - max(canvas.minX, editor.minX), height: canvas.height)
        guard column.width > 0 else { return nil }
        var regions = [column]
        if let keyboard, keyboard.intersects(column) {
            let blocked = keyboard.intersection(column)
            regions = [
                CGRect(x: column.minX, y: column.minY, width: column.width, height: blocked.minY - column.minY),
                CGRect(x: column.minX, y: blocked.maxY, width: column.width, height: column.maxY - blocked.maxY),
                CGRect(x: column.minX, y: blocked.minY, width: blocked.minX - column.minX, height: blocked.height),
                CGRect(x: blocked.maxX, y: blocked.minY, width: column.maxX - blocked.maxX, height: blocked.height),
            ]
        }
        let minimumWidth = min(220, column.width), desiredHeight = CGFloat(min(count, 6)) * rowHeight
        var candidates: [(CGRect, CGFloat)] = []
        for region in regions where region.width >= minimumWidth {
            for below in [true, false] {
                let top = below ? max(region.minY, caret.maxY + 6) : region.minY
                let bottom = below ? region.maxY : min(region.maxY, caret.minY - 6)
                let height = min(desiredHeight, bottom - top)
                guard height >= min(desiredHeight, rowHeight) else { continue }
                let width = min(460, region.width)
                let x = min(max(caret.minX, region.minX), region.maxX - width)
                let y = below ? top : bottom - height
                let frame = CGRect(x: x, y: y, width: width, height: height)
                let distance = below ? frame.minY - caret.maxY : caret.minY - frame.maxY
                let score = distance + abs(frame.minX - caret.minX) + (below ? 0 : 12)
                candidates.append((frame, score))
            }
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }
}

@MainActor final class MobileSQLCompletionPopup: UIView, UITableViewDataSource, UITableViewDelegate {
    private let table = UITableView(frame: .zero, style: .plain)
    private weak var editor: UITextView?
    private var items: [SQLCompletionItem] = []
    private(set) var selected = 0
    var accept: ((Int) -> Void)?
    var dismiss: (() -> Void)?
    var keyboardFrameInWindow: CGRect? { didSet { setNeedsLayout() } }
    var candidateFrame: CGRect { table.frame }

    init(editor: UITextView) {
        self.editor = editor
        super.init(frame: .zero)
        accessibilityIdentifier = "sqlCompletionOverlay"
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.backgroundColor = .secondarySystemBackground
        table.layer.cornerRadius = 12; table.layer.cornerCurve = .continuous
        table.layer.borderWidth = 1; table.clipsToBounds = true
        table.dataSource = self; table.delegate = self
        table.rowHeight = MobileSQLCompletionLayout.rowHeight
        table.separatorInset = .init(top: 0, left: 12, bottom: 0, right: 12)
        table.accessibilityIdentifier = "sqlCompletionPopup"
        table.keyboardDismissMode = .none
        addSubview(table)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardDidHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deactivate), name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ items: [SQLCompletionItem]) {
        let old = self.items.indices.contains(selected) ? self.items[selected] : nil
        self.items = items
        selected = old.flatMap { previous in items.firstIndex { $0.label == previous.label && $0.insertionText == previous.insertionText } } ?? 0
        guard let window = editor?.window else { removeFromSuperview(); return }
        window.keyboardLayoutGuide.followsUndockedKeyboard = true
        if superview !== window { removeFromSuperview(); frame = window.bounds; window.addSubview(self) }
        table.reloadData(); setNeedsLayout(); layoutIfNeeded()
        selectRow()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let editor, let window, let position = editor.selectedTextRange?.end else { table.isHidden = true; return }
        let caret = editor.convert(editor.caretRect(for: position), to: self)
        let editorFrame = editor.convert(editor.bounds, to: self)
        let visibleBounds = convert(window.safeAreaLayoutGuide.layoutFrame, from: window)
        let guide = convert(window.keyboardLayoutGuide.layoutFrame, from: window)
        let keyboard = keyboardFrameInWindow ?? (guide.height > window.safeAreaInsets.bottom + 1 ? guide : nil)
        guard let placement = MobileSQLCompletionLayout.frame(in: visibleBounds, editor: editorFrame, caret: caret, keyboard: keyboard, count: items.count) else {
            table.isHidden = true; return
        }
        table.isHidden = false
        if table.frame != placement { table.frame = placement }
        table.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !table.isHidden && table.frame.contains(point)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        selectRow()
    }
    private func selectRow() {
        guard items.indices.contains(selected) else { return }
        let path = IndexPath(row: selected, section: 0)
        table.selectRow(at: path, animated: false, scrollPosition: .none)
        table.scrollToRow(at: path, at: .none, animated: false)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "completion") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "completion")
        let item = items[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.label; content.secondaryText = item.detail
        content.textProperties.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.font = .systemFont(ofSize: 11)
        content.secondaryTextProperties.numberOfLines = 1
        content.directionalLayoutMargins = .init(top: 4, leading: 12, bottom: 4, trailing: 12)
        cell.contentConfiguration = content
        cell.backgroundColor = .secondarySystemBackground
        let selectedBackground = UIView(); selectedBackground.backgroundColor = MobileAppearance.selectionColor
        cell.selectedBackgroundView = selectedBackground
        cell.accessibilityLabel = item.label; cell.accessibilityHint = item.detail
        cell.accessibilityTraits = .button
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { accept?(indexPath.row) }

    @objc private func keyboardChanged(_ notification: Notification) {
        guard let window, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardFrameInWindow = window.convert(frame, from: window.screen.coordinateSpace)
        layoutIfNeeded()
    }
    @objc private func keyboardHidden() { keyboardFrameInWindow = nil; layoutIfNeeded() }
    @objc private func deactivate() { dismiss?() }
}
