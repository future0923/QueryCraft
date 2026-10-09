import AppKit
import Combine
import SwiftUI

@MainActor
final class WorkspaceDataCellDateAccessory: NSObject, NSPopoverDelegate {
    private weak var editor: NSTextField?
    private let type: WorkspaceSQLDateType
    private let isNullable: Bool
    private let apply: (WorkspaceDatabaseInspectorMutation) -> Void
    private let endEditing: () -> Void
    private let button = WorkspaceSQLDatePickerButton()
    private var popover: NSPopover?

    var isPresented: Bool { popover != nil }

    init(editor: NSTextField, type: WorkspaceSQLDateType, isNullable: Bool,
         apply: @escaping (WorkspaceDatabaseInspectorMutation) -> Void,
         endEditing: @escaping () -> Void) {
        self.editor = editor
        self.type = type
        self.isNullable = isNullable
        self.apply = apply
        self.endEditing = endEditing
        super.init()
        button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: AppCopy.current.text("选择日期", "Choose date"))
        button.bezelStyle = .inline
        button.isBordered = false
        button.refusesFirstResponder = true
        button.target = self
        button.action = #selector(showPicker)
        button.toolTip = AppCopy.current.text("选择日期（⌥↓）", "Choose date (⌥↓)")
        button.setAccessibilityLabel(AppCopy.current.text("选择日期", "Choose date"))
        button.setAccessibilityIdentifier("dataCellDatePickerButton")
        editor.superview?.addSubview(button, positioned: .above, relativeTo: editor)
    }

    /// The text field and button share the original cell's bounds.
    func layout(in cell: NSRect) {
        let width = min(24, cell.width)
        editor?.frame = NSRect(x: cell.minX, y: cell.minY, width: max(0, cell.width - width), height: cell.height)
        button.frame = NSRect(x: cell.maxX - width, y: cell.minY, width: width, height: cell.height)
        if let parent = editor?.superview, !parent.visibleRect.intersects(cell) {
            close(restoresFocus: false)
        }
    }

    @objc func showPicker() {
        guard popover == nil, let editor, editor.window != nil else { return }
        let text = editor.currentEditor()?.string ?? editor.stringValue
        let controller = WorkspaceSQLDatePickerController(type: type, text: text, isNullable: isNullable)
        controller.apply = { [weak self] mutation in
            guard let self, self.editor?.superview != nil else { return }
            self.close(restoresFocus: false)
            self.apply(mutation)
            self.restoreFocus()
        }
        controller.cancel = { [weak self] in self?.close(restoresFocus: true) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        popover.contentSize = controller.view.fittingSize
        // Set before showing: transferring focus must not commit the inline edit.
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func remove() {
        close(restoresFocus: false)
        button.removeFromSuperview()
    }

    private func close(restoresFocus: Bool) {
        let closingPopover = popover
        popover = nil
        closingPopover?.close()
        if restoresFocus { restoreFocus() }
    }

    private func restoreFocus() {
        guard let editor, editor.superview != nil, editor.window?.isKeyWindow == true else { return }
        editor.window?.makeFirstResponder(editor)
        editor.currentEditor()?.moveToEndOfDocument(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        let closingID = notification.object.map { ObjectIdentifier($0 as AnyObject) }
        MainActor.assumeIsolated {
            guard let popover, ObjectIdentifier(popover) == closingID else { return }
            self.popover = nil
            endEditing()
        }
    }

    isolated deinit {
        popover?.delegate = nil
        popover?.close()
        button.removeFromSuperview()
    }
}

@MainActor
final class WorkspaceSQLDatePickerController: NSViewController {
    let type: WorkspaceSQLDateType
    private var value: WorkspaceSQLDateValue
    private let originalText: String
    private let isNullable: Bool
    private let dateModel: WorkspaceSQLDateEditingModel
    private var dateHost: NSHostingView<WorkspaceSQLDateEditorView>?
    private let timeModel: WorkspaceSQLTimeEditingModel
    private var timeHost: NSHostingView<WorkspaceSQLTimeEditorView>?
    private let applyButton = NSButton()
    var apply: ((WorkspaceDatabaseInspectorMutation) -> Void)?
    var cancel: (() -> Void)?

    init(type: WorkspaceSQLDateType, text: String, isNullable: Bool) {
        self.type = type
        originalText = text
        value = type.parse(text) ?? type.seed()
        self.isNullable = isNullable
        dateModel = WorkspaceSQLDateEditingModel(date: value.date)
        timeModel = WorkspaceSQLTimeEditingModel(date: value.date, fraction: value.fraction)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let copy = AppCopy.current
        let panelWidth: CGFloat = 320
        let contentWidth = panelWidth - 28
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 20
        glass.layer?.borderWidth = 0.7
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        glass.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glass)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glass.topAnchor.constraint(equalTo: view.topAnchor),
            glass.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            view.widthAnchor.constraint(equalToConstant: panelWidth),
        ])
        if type.includesDate {
            let dateView = WorkspaceSQLDateEditorView(
                model: dateModel,
                onChange: { [weak self] date in self?.dateChanged(date) },
                onValidityChange: { [weak self] _ in self?.updateValidity() }
            )
            let dateHost = NSHostingView(rootView: dateView)
            dateHost.setAccessibilityIdentifier("sqlDateDateEditor")
            dateHost.translatesAutoresizingMaskIntoConstraints = false
            dateHost.widthAnchor.constraint(equalToConstant: 292).isActive = true
            dateHost.heightAnchor.constraint(equalToConstant: 42).isActive = true
            self.dateHost = dateHost
            stack.addArrangedSubview(dateHost)
        }
        if type.includesTime {
            let timeView = WorkspaceSQLTimeEditorView(
                model: timeModel,
                onChange: { [weak self] hour, minute, second, fraction in
                    self?.timeChanged(hour: hour, minute: minute, second: second, fraction: fraction)
                },
                onValidityChange: { [weak self] _ in self?.updateValidity() }
            )
            let timeHost = NSHostingView(rootView: timeView)
            timeHost.setAccessibilityIdentifier("sqlDateTimeEditor")
            timeHost.translatesAutoresizingMaskIntoConstraints = false
            timeHost.widthAnchor.constraint(equalToConstant: 292).isActive = true
            timeHost.heightAnchor.constraint(equalToConstant: 42).isActive = true
            self.timeHost = timeHost
            stack.addArrangedSubview(timeHost)
        }
        let nowButton = NSButton(title: copy.text("现在", "Now"), target: self, action: #selector(useNow))
        nowButton.bezelStyle = .rounded
        nowButton.controlSize = .regular
        nowButton.setAccessibilityIdentifier("sqlDateNowButton")
        let nullButton = NSButton(title: "NULL", target: self, action: #selector(useNull))
        nullButton.bezelStyle = .rounded
        nullButton.controlSize = .regular
        nullButton.isEnabled = isNullable
        applyButton.title = copy.text("应用", "Apply")
        applyButton.bezelStyle = .rounded
        applyButton.controlSize = .regular
        applyButton.target = self
        applyButton.action = #selector(applyValue)
        applyButton.keyEquivalent = "\r"
        let buttons: [NSView] = [nowButton, nullButton, applyButton]
        let footer = NSStackView(views: buttons)
        footer.spacing = 6
        footer.alignment = .centerY
        footer.distribution = .fillEqually
        footer.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        stack.addArrangedSubview(footer)
        updateValidity()
    }

    private func timeChanged(hour: Int, minute: Int, second: Int, fraction: String) {
        let calendar = WorkspaceSQLDateType.calendar
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: value.date)
        components.hour = hour
        components.minute = minute
        components.second = second
        if let date = calendar.date(from: components) {
            value.date = date
        }
        value.fraction = fraction
        updateValidity()
    }

    private func dateChanged(_ date: Date) {
        let calendar = WorkspaceSQLDateType.calendar
        let time = calendar.dateComponents([.hour, .minute, .second], from: value.date)
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        guard let combined = calendar.date(from: components) else { return }
        value.date = combined
        updateValidity()
    }

    @objc private func useNow() {
        let zone = WorkspaceSQLDateValue.offsetSeconds(value.zoneSuffix).flatMap(TimeZone.init(secondsFromGMT:)) ?? .current
        let seeded = type.seed(timeZone: zone)
        value.date = seeded.date
        value.fraction = seeded.fraction
        dateModel.sync(date: seeded.date)
        timeModel.sync(date: seeded.date, fraction: seeded.fraction)
        updateValidity()
    }

    @objc private func useNull() { apply?(.null) }
    @objc private func cancelPicker() { cancel?() }
    override func cancelOperation(_ sender: Any?) { cancel?() }

    @objc private func applyValue() {
        if type.includesTime && type.fractionalPrecision != 0 {
            value.fraction = timeModel.fractionText
        }
        guard let text = type.string(for: value) else { return }
        apply?(.value(text))
    }

    private func updateValidity() {
        let dateValid = !type.includesDate || dateModel.isValid
        let timeValid = !type.includesTime || timeModel.isValid
        applyButton.isEnabled = dateValid && timeValid && type.string(for: value) != nil
    }

}

@MainActor
private final class WorkspaceSQLDatePickerButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        // Cover the table's drawn text behind the inline accessory.
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}
