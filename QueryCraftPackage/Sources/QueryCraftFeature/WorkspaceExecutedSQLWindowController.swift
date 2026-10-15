import AppKit
import CodeEditSourceEditor
import SwiftUI

struct WorkspaceExecutedSQLControl: View {
    let sql: String
    var highlightContext: SQLHighlightContext = .generic
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: sql.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.joined(separator: " "))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    WorkspaceExecutedSQLWindowController.show(sql: sql, context: highlightContext)
                }
                .accessibilityAction(named: AppCopy.current.text("查看完整 SQL", "View Full SQL")) {
                    WorkspaceExecutedSQLWindowController.show(sql: sql, context: highlightContext)
                }

            Button {
                WorkspaceExecutedSQLWindowController.show(sql: sql, context: highlightContext)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(AppCopy.current.text("查看完整 SQL", "View Full SQL"))
            .accessibilityLabel(AppCopy.current.text("查看完整 SQL", "View Full SQL"))
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(sql)
    }
}

@MainActor
final class WorkspaceExecutedSQLWindowController: NSWindowController, NSWindowDelegate {
    private static var windows: [String: WorkspaceExecutedSQLWindowController] = [:]
    private let sql: String
    private let key: String

    static func show(sql: String, context: SQLHighlightContext = .generic) {
        let key = context.dialect.rawValue + String(context.ansiQuotes) + sql
        if let existing = windows[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let parent = NSApp.keyWindow
        let controller = WorkspaceExecutedSQLWindowController(sql: sql, context: context, key: key)
        windows[key] = controller
        if let available = parent?.screen?.visibleFrame.insetBy(dx: 24, dy: 24),
            let window = controller.window {
            let maximum = window.contentRect(forFrameRect: available).size
            window.setContentSize(NSSize(
                width: min(900, maximum.width), height: min(600, maximum.height)
            ))
            let anchor = parent?.frame ?? available
            window.setFrameOrigin(NSPoint(
                x: min(max(anchor.midX - window.frame.width / 2, available.minX),
                       available.maxX - window.frame.width),
                y: min(max(anchor.midY - window.frame.height / 2, available.minY),
                       available.maxY - window.frame.height)
            ))
        } else {
            controller.window?.center()
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(sql: String, context: SQLHighlightContext, key: String) {
        self.key = key
        self.sql = sql
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppCopy.current.text("完整 SQL", "Full SQL")
        window.contentMinSize = NSSize(width: 400, height: 240)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = NSHostingController(
            rootView: WorkspaceExecutedSQLWindowView(sql: sql, highlightContext: context)
        )
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func windowWillClose(_ notification: Notification) {
        if Self.windows[key] === self { Self.windows[key] = nil }
    }
}

struct WorkspaceExecutedSQLWindowView: View {
    let sql: String
    let highlightContext: SQLHighlightContext
    @Environment(\.colorScheme) private var colorScheme
    @State private var preferences = ApplicationPreferences.shared
    @State private var fontSize: CGFloat = 14
    @State private var highlights: [SQLSyntaxHighlight] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(AppCopy.current.text("缩小文字", "Decrease Text Size"),
                       systemImage: "minus.magnifyingglass") {
                    fontSize = max(10, fontSize - 2)
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut("-", modifiers: .command)
                .disabled(fontSize <= 10)

                Text("\(Int(fontSize)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button(AppCopy.current.text("放大文字", "Increase Text Size"),
                       systemImage: "plus.magnifyingglass") {
                    fontSize = min(40, fontSize + 2)
                }
                .labelStyle(.iconOnly)
                .keyboardShortcut("=", modifiers: .command)
                .disabled(fontSize >= 40)

                Spacer()

                Button(AppCopy.current.text("复制 SQL", "Copy SQL"),
                       systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                }
            }
            .controlSize(.small)
            .padding(10)

            Divider()

            ScrollView {
                Text(highlightedSQL)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: theme.background))
        .accessibilityIdentifier("executedSQLWindow")
        .task(id: sql) {
            highlights = []
            do {
                let parser = try SQLStructuralParser()
                let source = SQLSourceSnapshot(revision: SQLSourceRevision(1), text: sql)
                _ = try await parser.parse(source)
                let parsedHighlights = try await parser.highlights(
                    in: SQLSourceRange(location: 0, length: (sql as NSString).length),
                    revision: source.revision, context: highlightContext
                )
                try Task.checkCancellation()
                highlights = parsedHighlights
            } catch {
                // Keep the original SQL readable if highlighting is unavailable or cancelled.
            }
        }
    }

    private var theme: EditorTheme {
        WorkspaceEditorTheme.make(
            for: colorScheme == .dark ? .darkAqua : .aqua,
            settings: preferences.editorColors
        )
    }

    private var highlightedSQL: AttributedString {
        Self.highlightedSQL(sql, highlights: highlights, theme: theme, fontSize: fontSize)
    }

    static func highlightedSQL(_ sql: String, highlights: [SQLSyntaxHighlight], theme: EditorTheme, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString(sql)
        result.foregroundColor = Color(nsColor: theme.text.color)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        result.font = Font(font)
        for highlight in highlights {
            guard let sourceRange = Range(highlight.range.nsRange, in: sql),
                  let lowerBound = AttributedString.Index(sourceRange.lowerBound, within: result),
                  let upperBound = AttributedString.Index(sourceRange.upperBound, within: result)
            else { continue }

            let capture = WorkspaceSQLLanguageService.captureName(for: highlight.kind)
            let color = theme.colorFor(capture)
            result[lowerBound..<upperBound].foregroundColor = Color(nsColor: color)
            result[lowerBound..<upperBound].font = Font(theme.fontFor(for: capture, from: font))
        }
        return result
    }
}
