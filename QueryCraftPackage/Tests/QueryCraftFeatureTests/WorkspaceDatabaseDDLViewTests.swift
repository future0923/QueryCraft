import AppKit
import CodeEditTextView
import SwiftUI
import Testing
@testable import QueryCraftFeature

private final class SelectionNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
@Suite(.serialized)
struct WorkspaceDatabaseDDLViewTests {
    @Test("Dragging into the sidebar tracks line starts without horizontal autoscroll")
    func draggingIntoSidebarTracksVisibleLineStarts() throws {
        let ddl = (1...40).map { "SELECT column_\($0) FROM table_\($0);" }.joined(separator: "\n")
        let mounted = try mountDDL(ddl)
        defer { mounted.window.close() }
        let textView = mounted.textView
        textView.layoutManager.layoutLines()
        textView.updateFrameIfNeeded()

        let visibleRect = textView.visibleRect
        #expect(visibleRect.minX <= 1)
        let anchorPoint = CGPoint(x: visibleRect.midX, y: visibleRect.minY + 30)
        let anchorOffset = try #require(textView.layoutManager.textOffsetAtPoint(anchorPoint))
        let outsidePoint = CGPoint(x: visibleRect.minX - 240, y: visibleRect.minY + 140)
        let lineStartPoint = CGPoint(
            x: textView.layoutManager.edgeInsets.left,
            y: outsidePoint.y
        )
        let lineStartOffset = try #require(textView.layoutManager.textOffsetAtPoint(lineStartPoint))

        textView.mouseDown(with: try mouseEvent(.leftMouseDown, at: anchorPoint, in: textView))
        textView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: outsidePoint, in: textView))

        #expect(textView.visibleRect.minX <= 1)
        #expect(
            textView.selectedRange()
                == NSRange(
                    location: min(anchorOffset, lineStartOffset),
                    length: abs(anchorOffset - lineStartOffset)
                )
        )

        textView.mouseUp(with: try mouseEvent(.leftMouseUp, at: outsidePoint, in: textView))
    }

    @Test("DDL drag publishes its final selection once on mouse up")
    func ddlDragPublishesFinalSelectionOnceOnMouseUp() throws {
        let mounted = try mountDDL("SELECT id, name, email FROM users;")
        defer { mounted.window.close() }
        let textView = mounted.textView
        textView.layoutManager.layoutLines()
        textView.updateFrameIfNeeded()

        let visibleRect = textView.visibleRect
        let anchorPoint = CGPoint(x: visibleRect.minX + 20, y: visibleRect.minY + 20)
        let dragPoint = CGPoint(x: visibleRect.minX + 180, y: visibleRect.minY + 20)
        let notificationCount = SelectionNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: textView.selectionManager,
            queue: nil
        ) { _ in
            notificationCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        textView.mouseDown(with: try mouseEvent(.leftMouseDown, at: anchorPoint, in: textView))
        let countAfterMouseDown = notificationCount.value
        textView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: dragPoint, in: textView))
        #expect(notificationCount.value == countAfterMouseDown)
        textView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: dragPoint, in: textView))
        #expect(notificationCount.value == countAfterMouseDown)
        textView.mouseUp(with: try mouseEvent(.leftMouseUp, at: dragPoint, in: textView))

        #expect(notificationCount.value == countAfterMouseDown + 1)
    }

    @Test("Dragging above or below DDL remains bounded to the visible editor")
    func verticalDragSelectionOutsideDDLRemainsAtVisibleEdges() throws {
        let ddl = (1...120).map { "SELECT \($0);" }.joined(separator: "\n")
        let mounted = try mountDDL(ddl)
        defer { mounted.window.close() }
        let textView = mounted.textView
        let scrollView = try #require(textView.enclosingScrollView)
        textView.layoutManager.layoutLines()
        textView.updateFrameIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 420))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        for dragAbove in [true, false] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 420))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            let visibleRect = textView.visibleRect
            #expect(visibleRect.minY > 0)
            let anchorPoint = CGPoint(x: visibleRect.minX + 160, y: visibleRect.midY)
            let anchorOffset = try #require(textView.layoutManager.textOffsetAtPoint(anchorPoint))
            let outsidePoint = CGPoint(
                x: anchorPoint.x,
                y: dragAbove ? visibleRect.minY - 180 : visibleRect.maxY + 180
            )

            textView.mouseDown(with: try mouseEvent(.leftMouseDown, at: anchorPoint, in: textView))
            textView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: outsidePoint, in: textView))
            let scrolledVisibleRect = textView.visibleRect
            let scrolledEdgePoint = CGPoint(
                x: anchorPoint.x,
                y: dragAbove ? scrolledVisibleRect.minY : scrolledVisibleRect.maxY
            )
            let edgeOffset = try #require(textView.layoutManager.textOffsetAtPoint(scrolledEdgePoint))
            textView.mouseUp(with: try mouseEvent(.leftMouseUp, at: outsidePoint, in: textView))

            #expect(
                textView.selectedRange()
                    == NSRange(
                        location: min(anchorOffset, edgeOffset),
                        length: abs(anchorOffset - edgeOffset)
                    )
            )
        }
    }

    @Test("Dragging outside a horizontally scrolled DDL view stops at the visible edge")
    func dragSelectionOutsideVisibleDDLStopsAtVisibleEdge() throws {
        let ddl = "SELECT " + String(repeating: "column_name, ", count: 180) + "final_column;"
        let mounted = try mountDDL(ddl)
        defer { mounted.window.close() }
        let textView = mounted.textView
        let scrollView = try #require(textView.enclosingScrollView)
        textView.layoutManager.layoutLines()
        textView.updateFrameIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 360, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let visibleRect = textView.visibleRect
        #expect(visibleRect.minX > 0)
        let anchorPoint = CGPoint(
            x: visibleRect.minX + min(visibleRect.width * 0.6, 280),
            y: visibleRect.minY + 20
        )
        let outsidePoint = CGPoint(
            x: visibleRect.minX - 120,
            y: anchorPoint.y
        )
        let anchorOffset = try #require(textView.layoutManager.textOffsetAtPoint(anchorPoint))
        let visibleEdgeOffset = try #require(
            textView.layoutManager.textOffsetAtPoint(
                CGPoint(x: visibleRect.minX, y: anchorPoint.y)
            )
        )

        textView.mouseDown(with: try mouseEvent(.leftMouseDown, at: anchorPoint, in: textView))
        textView.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: outsidePoint, in: textView))
        textView.mouseUp(with: try mouseEvent(.leftMouseUp, at: outsidePoint, in: textView))

        #expect(
            textView.selectedRange()
                == NSRange(
                    location: min(anchorOffset, visibleEdgeOffset),
                    length: abs(anchorOffset - visibleEdgeOffset)
                )
        )
    }

    @Test("Light appearance uses syntax colors")
    func lightAppearanceUsesSyntaxColors() async throws {
        try await assertPresentation(
            colorScheme: .light,
            appearanceName: .aqua
        )
    }

    @Test("Dark appearance uses syntax colors")
    func darkAppearanceUsesSyntaxColors() async throws {
        try await assertPresentation(
            colorScheme: .dark,
            appearanceName: .darkAqua
        )
    }

    private func assertPresentation(
        colorScheme: ColorScheme,
        appearanceName: NSAppearance.Name
    ) async throws {
        let ddl = """
        CREATE TABLE users (
            id BIGINT NOT NULL,
            name VARCHAR(80) DEFAULT 'unknown'
        );
        """
        let hostingView = NSHostingView(
            rootView: WorkspaceDatabaseDDLView(ddl: ddl)
                .environment(\.colorScheme, colorScheme)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 320)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearanceName)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let textView = try #require(findTextView(in: hostingView))
        #expect(textView.string == ddl)
        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        let scrollView = try #require(textView.enclosingScrollView)
        #expect(scrollView.automaticallyAdjustsContentInsets)

        let source = ddl as NSString
        let keywordRange = source.range(of: "CREATE")
        let stringRange = source.range(of: "'unknown'")
        let theme = WorkspaceEditorTheme.make(for: appearanceName)
        var keywordColor: NSColor?
        var stringColor: NSColor?

        for _ in 0..<40 {
            keywordColor = textView.textStorage.attribute(
                .foregroundColor,
                at: keywordRange.location,
                effectiveRange: nil
            ) as? NSColor
            stringColor = textView.textStorage.attribute(
                .foregroundColor,
                at: stringRange.location,
                effectiveRange: nil
            ) as? NSColor
            if keywordColor == theme.keywords.color,
               stringColor == theme.strings.color
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(keywordColor == theme.keywords.color)
        #expect(stringColor == theme.strings.color)
    }

    private func findTextView(in view: NSView) -> TextView? {
        if let textView = view as? TextView { return textView }
        return view.subviews.lazy.compactMap(findTextView(in:)).first
    }

    private func mountDDL(
        _ ddl: String
    ) throws -> (window: NSWindow, textView: TextView) {
        let hostingView = NSHostingView(
            rootView: WorkspaceDatabaseDDLView(ddl: ddl)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        return (window, try #require(findTextView(in: hostingView)))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: CGPoint,
        in textView: TextView
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type,
                location: textView.convert(point, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: textView.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            )
        )
    }
}
