import AppKit
@testable import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor
@Suite(.serialized)
struct WorkspaceJSONTextViewTests {
    private let source = """
    {
      "name" : "沈阳",
      "items" : [
        true,
        null,
        18446744073709551615
      ]
    }
    """

    @Test func readerHasDistinctColorsLineNumbersAndLosslessFolding() async throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: WorkspaceJSONTextView(
                text: .constant(source), accessibilityLabel: "JSON"
            ).environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            let window = mount(host, appearance: appearance)
            defer { window.orderOut(nil); window.contentView = nil }
            let textView = try #require(findText(in: host))
            let controller = try #require(findController(for: textView))
            #expect(!textView.isEditable)
            #expect(textView.isSelectable)
            #expect(controller.configuration.peripherals.showGutter)
            #expect(controller.gutterView.showFoldingRibbon)
            #expect(textView.string == source)

            let client = try #require(controller.treeSitterClient)
            let highlights = try await withCheckedThrowingContinuation { continuation in
                client.queryHighlightsFor(textView: textView, range: NSRange(location: 0, length: (source as NSString).length)) {
                    continuation.resume(with: $0)
                }
            }
            for (token, capture) in [("\"name\"", CaptureName.type), ("\"沈阳\"", .string), ("true", .boolean), ("null", .boolean), ("18446744073709551615", .number)] {
                let range = (source as NSString).range(of: token)
                #expect(highlights.contains { $0.range == range && $0.capture == capture })
            }
            let colors = [CaptureName.type, .string, .boolean, .number].compactMap {
                controller.attributesFor($0)[.foregroundColor] as? NSColor
            }
            #expect(Set(colors).count == 4)

            let ribbon = controller.gutterView.foldingRibbon
            let model = try #require(ribbon.model)
            for _ in 0..<100 {
                if !model.getFolds(in: 0..<(source as NSString).length).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let fold = try #require(model.getFolds(in: 0..<(source as NSString).length).first)
            textView.selectionManager.setSelectedRanges([NSRange(location: fold.range.lowerBound, length: 0)])
            let action = try #require(textView.accessibilityCustomActions()?.first)
            #expect(action.handler?() == true)
            #expect(!textView.layoutManager.attachments.getAttachmentsOverlapping(NSRange(fold.range)).isEmpty)
            textView.selectAll(nil)
            #expect(textView.selectedRange().length == (source as NSString).length)
            #expect(textView.textStorage.attributedSubstring(from: textView.selectedRange()).string == source)
            textView.insertText("accidental edit")
            #expect(textView.string == source)
            textView.selectionManager.setSelectedRanges([NSRange(location: fold.range.lowerBound, length: 0)])
            #expect(action.handler?() == true)
            #expect(textView.string == source)
        }
    }

    @Test func bindingRefreshesMountedEditorAndDiscardedDraft() async throws {
        var value = source
        let host = NSHostingView(rootView: WorkspaceJSONTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isEditable: true, accessibilityLabel: "JSON"
        ))
        let window = mount(host, appearance: .aqua)
        defer { window.orderOut(nil); window.contentView = nil }
        let textView = try #require(findText(in: host))
        window.makeFirstResponder(textView)
        textView.selectAll(nil)
        textView.insertText("{\"name\":\"新值\"}")
        #expect(value == "{\"name\":\"新值\"}")

        value = source
        host.rootView = WorkspaceJSONTextView(
            text: Binding(get: { value }, set: { value = $0 }),
            isEditable: true, accessibilityLabel: "JSON"
        )
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if textView.string == source { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(findText(in: host) === textView)
        #expect(textView.string == source)
    }

    @Test func largeFoldBatchesDoNotOutliveDocumentReplacement() async throws {
        let largeSource = "{\n  \"items\" : [\n" + (0..<300).map { "    \($0)" }.joined(separator: ",\n") + "\n  ],\n  \"tail\" : true\n}"
        let host = NSHostingView(rootView: WorkspaceJSONTextView(
            text: .constant(largeSource), accessibilityLabel: "JSON"
        ))
        let window = mount(host, appearance: .aqua)
        defer { window.orderOut(nil); window.contentView = nil }
        let textView = try #require(findText(in: host))
        let controller = try #require(findController(for: textView))
        let model = try #require(controller.gutterView.foldingRibbon.model)
        for _ in 0..<100 {
            if model.getCachedFoldAt(lineNumber: 0) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.getCachedFoldAt(lineNumber: 0)?.range.upperBound == (largeSource as NSString).length - 1)
        controller.setText(largeSource + "\n")
        await Task.yield()
        controller.setText(source)
        for _ in 0..<100 {
            if model.getCachedFoldAt(lineNumber: 0)?.range.upperBound == (source as NSString).length - 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.getCachedFoldAt(lineNumber: 0)?.range.upperBound == (source as NSString).length - 1)
        #expect(textView.string == source)
    }

    private func mount(_ view: NSView, appearance: NSAppearance.Name) -> NSWindow {
        view.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return window
    }

    private func findText(in view: NSView) -> TextView? {
        if let text = view as? TextView { return text }
        return view.subviews.lazy.compactMap(findText(in:)).first
    }

    private func findController(for view: NSView) -> TextViewController? {
        var responder: NSResponder? = view
        while let current = responder {
            if let controller = current as? TextViewController { return controller }
            responder = current.nextResponder
        }
        return nil
    }
}
