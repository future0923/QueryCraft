import AppKit
import SwiftUI

struct SchemaComparisonDDLLineDiff: Sendable {
    let source: Set<Int>
    let target: Set<Int>
    static func compare(source: String, target: String) -> Self {
        let s = source.components(separatedBy: "\n"), t = target.components(separatedBy: "\n")
        var additions: Set<Int> = [], removals: Set<Int> = []
        for change in s.difference(from: t) {
            switch change {
            case .insert(let offset, _, _): additions.insert(offset)
            case .remove(let offset, _, _): removals.insert(offset)
            }
        }
        return .init(source: additions, target: removals)
    }
}

/// Real text differences use standard NSTextView background attributes. The
/// surrounding split view and scroll views retain system sizing and accessibility.
struct SchemaComparisonDDLPairView: NSViewControllerRepresentable {
    let source: String
    let target: String
    var objectID: String? = nil
    var sourceDatabase = ""
    var targetDatabase = ""
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSViewController(context: Context) -> SchemaComparisonDDLSplitViewController {
        let controller = SchemaComparisonDDLSplitViewController()
        for index in 0...1 {
            let scroll = ScrollView()
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            let text = NSTextView()
            text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
            text.isAutomaticSpellingCorrectionEnabled = false; text.isContinuousSpellCheckingEnabled = false
            text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
            text.isHorizontallyResizable = true; text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.textContainerInset = NSSize(width: 12, height: 10)
            text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            text.setAccessibilityIdentifier(index == 0 ? "schemaComparisonSourceDDL" : "schemaComparisonTargetDDL")
            text.setAccessibilityLabel(index == 0 ? AppCopy.current.text("源 DDL，绿色为差异行", "Source DDL; changed lines are green") : AppCopy.current.text("目标 DDL，红色为差异行", "Target DDL; changed lines are red"))
            scroll.documentView = text
            scroll.verticalRulerView = SchemaComparisonLineNumberRuler(textView: text, scrollView: scroll)
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
            scroll.scrolled = { [weak coordinator = context.coordinator] in coordinator?.synchronize(from: index) }
            let header = NSTextField(labelWithString: "")
            header.font = .preferredFont(forTextStyle: .caption1)
            header.textColor = .secondaryLabelColor; header.lineBreakMode = .byTruncatingMiddle
            let headerRow = NSStackView(views: [header])
            headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            headerRow.heightAnchor.constraint(equalToConstant: 30).isActive = true
            let separator = NSBox(); separator.boxType = .separator
            let empty = NSTextField(wrappingLabelWithString: index == 0
                ? AppCopy.current.text("源数据库中没有此对象", "This object does not exist in the source database")
                : AppCopy.current.text("目标数据库中没有此对象", "This object does not exist in the target database"))
            empty.font = .preferredFont(forTextStyle: .body)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.setAccessibilityIdentifier(index == 0 ? "schemaComparisonSourceMissing" : "schemaComparisonTargetMissing")
            let body = NSView()
            for child in [scroll, empty] { child.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(child) }
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: body.topAnchor), scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                empty.centerXAnchor.constraint(equalTo: body.centerXAnchor), empty.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                empty.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -40)
            ])
            let pane = NSView()
            for child in [headerRow, separator, body] { child.translatesAutoresizingMaskIntoConstraints = false; pane.addSubview(child) }
            NSLayoutConstraint.activate([
                headerRow.topAnchor.constraint(equalTo: pane.topAnchor), headerRow.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                headerRow.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                separator.topAnchor.constraint(equalTo: headerRow.bottomAnchor), separator.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: pane.trailingAnchor), separator.heightAnchor.constraint(equalToConstant: 1),
                body.topAnchor.constraint(equalTo: separator.bottomAnchor), body.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: pane.trailingAnchor), body.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
            ])
            context.coordinator.headers.append(header)
            context.coordinator.emptyLabels.append(empty)
            context.coordinator.scrolls.append(scroll); controller.addPane(pane)
        }
        return controller
    }
    func updateNSViewController(_ view: SchemaComparisonDDLSplitViewController, context: Context) {
        let coordinator = context.coordinator
        if coordinator.headers.count == 2 {
            coordinator.headers[0].stringValue = AppCopy.current.text("源 · 期望结构", "Source · Desired") + " · " + sourceDatabase
            coordinator.headers[1].stringValue = AppCopy.current.text("目标 · 当前结构", "Target · Current") + " · " + targetDatabase
        }
        let appearance = colorScheme == .dark ? "dark" : "light"
        guard coordinator.source != source || coordinator.target != target || coordinator.appearance != appearance || coordinator.objectID != objectID else { return }
        let objectChanged = coordinator.objectID != objectID
        coordinator.objectID = objectID
        coordinator.synchronizing = true
        defer { coordinator.synchronizing = false }
        coordinator.source = source; coordinator.target = target; coordinator.appearance = appearance
        let diff = SchemaComparisonDDLLineDiff.compare(source: source, target: target)
        for (i, value) in [source, target].enumerated() {
            guard let text = coordinator.scrolls[i].documentView as? NSTextView else { continue }
            let saved = coordinator.scrolls[i].contentView.bounds.origin
            coordinator.emptyLabels[i].isHidden = !value.isEmpty
            coordinator.scrolls[i].isHidden = value.isEmpty
            let string = NSMutableAttributedString(string: value, attributes: [.font: ApplicationPreferences.shared.editorFont(), .foregroundColor: NSColor.labelColor])
            let lines = value.components(separatedBy: "\n")
            let marked = i == 0 ? diff.source : diff.target
            let color = (i == 0 ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(colorScheme == .dark ? 0.18 : 0.12)
            var offset = 0
            for (line, content) in lines.enumerated() {
                let length = (content as NSString).length
                if marked.contains(line), length > 0 {
                    let range = NSRange(location: offset, length: length)
                    string.addAttribute(.backgroundColor, value: color, range: range)
                    if i == 1 { string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
                }
                offset += length + 1
            }
            if let tokens = try? SchemaComparisonDDL.tokens(value) {
                let keywords: Set<String> = ["CREATE", "TABLE", "VIEW", "FUNCTION", "PROCEDURE", "TRIGGER", "DEFAULT", "NOT", "NULL", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT", "UNIQUE", "CHECK", "ENGINE", "SELECT", "FROM", "WHERE", "BEGIN", "END", "RETURN", "RETURNS", "COMMENT", "ON", "DELETE", "UPDATE", "INSERT", "CASCADE"]
                for token in tokens {
                    let range = NSRange(token.range, in: value)
                    if token.text.hasPrefix("'") { string.addAttribute(.foregroundColor, value: NSColor.systemBrown, range: range) }
                    else if keywords.contains(token.keyword) { string.addAttribute(.foregroundColor, value: NSColor.systemIndigo, range: range) }
                    else if token.text.hasPrefix("/*") || token.text.hasPrefix("--") { string.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range) }
                }
            }
            text.textStorage?.setAttributedString(string)
            (coordinator.scrolls[i].verticalRulerView as? SchemaComparisonLineNumberRuler)?.updateLines()
            text.sizeToFit()
            text.backgroundColor = .textBackgroundColor
            let clip = coordinator.scrolls[i].contentView
            var restored = clip.bounds
            // AppKit reserves the native ruler using a negative clip origin.
            // Clamping that origin to zero hides the beginning of every line.
            restored.origin = objectChanged ? NSPoint(x: -clip.contentInsets.left, y: -clip.contentInsets.top) : saved
            clip.scroll(to: clip.constrainBoundsRect(restored).origin)
        }
    }
    @MainActor final class Coordinator {
        var source: String?, target: String?, objectID: String?, appearance = ""
        var scrolls: [ScrollView] = []
        var headers: [NSTextField] = []
        var emptyLabels: [NSTextField] = []
        var synchronizing = false
        func synchronize(from index: Int) {
            guard !synchronizing, scrolls.count == 2 else { return }
            synchronizing = true; defer { synchronizing = false }
            let from = scrolls[index], to = scrolls[1-index]
            let maximum = max(1, (from.documentView?.bounds.height ?? 0) - from.contentView.bounds.height)
            let targetMaximum = max(0, (to.documentView?.bounds.height ?? 0) - to.contentView.bounds.height)
            to.contentView.scroll(to: NSPoint(x: to.contentView.bounds.minX, y: from.contentView.bounds.minY / maximum * targetMaximum))
            to.reflectScrolledClipView(to.contentView)
        }
    }
    @MainActor final class ScrollView: NSScrollView {
        var scrolled: (() -> Void)?
        override func reflectScrolledClipView(_ clipView: NSClipView) { super.reflectScrolledClipView(clipView); scrolled?() }
    }
}

/// Let AppKit manage split-item constraints and user resizing. The first divider
/// position is set only after the controller is attached to its real window.
@MainActor final class SchemaComparisonDDLSplitViewController: NSSplitViewController {
    private var hasInitialLayout = false
    init() {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true; splitView.dividerStyle = .thin
        splitView.setAccessibilityIdentifier("schemaComparisonDDLSplit")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func addPane(_ pane: NSView) {
        let controller = NSViewController(); controller.view = pane
        let item = NSSplitViewItem(viewController: controller)
        item.minimumThickness = 180; item.preferredThicknessFraction = 0.5
        addSplitViewItem(item)
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !hasInitialLayout, view.window != nil, splitView.bounds.width > 360, splitViewItems.count == 2 else { return }
        hasInitialLayout = true
        splitView.setPosition((splitView.bounds.width - splitView.dividerThickness) / 2, ofDividerAt: 0)
    }
}

/// NSRulerView stays attached to the text's scroll view, so line numbers track
/// native scrolling and the configured editor font without adding text content.
@MainActor final class SchemaComparisonLineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts = [0]
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        setAccessibilityLabel(AppCopy.current.text("DDL 行号", "DDL line numbers"))
        setAccessibilityElement(false)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func updateLines() {
        guard let textView else { return }
        let string = textView.string as NSString
        lineStarts = [0]
        var offset = 0
        while offset < string.length {
            let next = NSMaxRange(string.lineRange(for: NSRange(location: offset, length: 0)))
            guard next > offset else { break }
            if next < string.length { lineStarts.append(next) }
            offset = next
        }
        numberFont = .monospacedDigitSystemFont(ofSize: max(10, (textView.font?.pointSize ?? 12) - 1), weight: .regular)
        let width = (String(max(1, lineStarts.count)) as NSString).size(withAttributes: [.font: numberFont]).width
        ruleThickness = max(38, ceil(width) + 20)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.controlBackgroundColor.setFill()
        bounds.intersection(rect).fill()
        guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let visible = text.visibleRect.offsetBy(dx: -text.textContainerOrigin.x, dy: -text.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { [self] _, used, _, glyphRange, _ in
            let character = layout.characterIndexForGlyph(at: glyphRange.location)
            var low = 0, high = lineStarts.count
            while low < high {
                let mid = (low + high) / 2
                if lineStarts[mid] <= character { low = mid + 1 } else { high = mid }
            }
            let label = String(max(1, low)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
            let size = label.size(withAttributes: attributes)
            let origin = convert(NSPoint(x: 0, y: used.minY + text.textContainerOrigin.y), from: text)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 10, y: origin.y), withAttributes: attributes)
        }
    }
}
