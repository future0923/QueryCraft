import AppKit
import SwiftUI

struct WorkspaceExecutedSQLControl: View {
    let sql: String
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
                    WorkspaceExecutedSQLWindowController.show(sql: sql)
                }
                .accessibilityAction(named: AppCopy.current.text("查看完整 SQL", "View Full SQL")) {
                    WorkspaceExecutedSQLWindowController.show(sql: sql)
                }

            Button {
                WorkspaceExecutedSQLWindowController.show(sql: sql)
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

    static func show(sql: String) {
        if let existing = windows[sql] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let parent = NSApp.keyWindow
        let controller = WorkspaceExecutedSQLWindowController(sql: sql)
        windows[sql] = controller
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

    private init(sql: String) {
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
            rootView: WorkspaceExecutedSQLWindowView(sql: sql)
        )
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func windowWillClose(_ notification: Notification) {
        if Self.windows[sql] === self { Self.windows[sql] = nil }
    }
}

private struct WorkspaceExecutedSQLWindowView: View {
    let sql: String
    @Environment(\.colorScheme) private var colorScheme
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
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("executedSQLWindow")
        .task(id: sql) {
            highlights = []
            do {
                let parser = try SQLStructuralParser()
                let source = SQLSourceSnapshot(revision: SQLSourceRevision(1), text: sql)
                _ = try await parser.parse(source)
                let parsedHighlights = try await parser.highlights(
                    in: SQLSourceRange(location: 0, length: (sql as NSString).length),
                    revision: source.revision
                )
                try Task.checkCancellation()
                highlights = parsedHighlights
            } catch {
                // Keep the original SQL readable if highlighting is unavailable or cancelled.
            }
        }
    }

    private var highlightedSQL: AttributedString {
        let theme = WorkspaceEditorTheme.make(
            for: colorScheme == .dark ? .darkAqua : .aqua
        )
        var result = AttributedString(sql)
        result.foregroundColor = Color(nsColor: theme.text.color)
        for highlight in highlights {
            guard let sourceRange = Range(highlight.range.nsRange, in: sql),
                  let lowerBound = AttributedString.Index(sourceRange.lowerBound, within: result),
                  let upperBound = AttributedString.Index(sourceRange.upperBound, within: result)
            else { continue }

            let color: NSColor
            switch highlight.kind {
            case .keyword, .boolean: color = theme.keywords.color
            case .comment: color = theme.comments.color
            case .variable, .property, .function, .parameter: color = theme.variables.color
            case .number: color = theme.numbers.color
            case .string: color = theme.strings.color
            case .type: color = theme.types.color
            case .attribute: color = theme.attributes.color
            }
            result[lowerBound..<upperBound].foregroundColor = Color(nsColor: color)
        }
        return result
    }
}
