import AppKit
import CodeEditTextView
@testable import CodeEditSourceEditor
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor
struct WorkspaceElasticsearchCreationInspectorLayoutTests {
    @Test func pastedSourceIsMultilineAndEditorFillsInspectorInBothAppearances() async throws {
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: "Elasticsearch", objectName: "logs", kind: .elasticsearchIndex)
        let request = WorkspaceDatabaseDataRowInsertRequest.makeElasticsearchDocument(
            selection: selection,
            pageColumns: [.init(id: 0, name: "name", type: "keyword"),
                          .init(id: 1, name: "count", type: "long")])
        let documents = try await WorkspaceElasticsearchDocumentPasteParser.shared.parse(
            .init(internalPayload: nil, tabSeparatedText: "name,count\nvalid-row,21"),
            targetColumnNames: [], request: request, targetKind: .index)
        let document = try #require(documents.first)
        let creation = WorkspacePreparedDocumentCreation(draft: document.draft,
            request: .init(method: .post, path: "/logs/_doc", body: document.draft.sourceJSON))

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let model = WorkspaceElasticsearchDocumentInspectorModel()
            model.installPastedCreation(creation, sourceText: document.sourceText)
            let context = WorkspaceElasticsearchDocumentInspectorContext(
                selection: selection, reference: nil, model: model, beginEditing: {},
                updateDraft: { _ in }, updateCreationDraft: { _, _, _ in }, endEditing: {})
            let hosting = NSHostingView(rootView: WorkspaceInspectorView(context: .elasticsearchDocument(context)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()

            let textView = try #require(findTextView(in: hosting))
            #expect(textView.string == document.sourceText)
            #expect(textView.string.components(separatedBy: "\n").count == 4)
            let scroll = try #require(textView.enclosingScrollView)
            #expect(scroll.frame.height > hosting.bounds.height / 2)
            #expect(scroll.frame.width > hosting.bounds.width * 0.8)
            let gutter = try #require(findGutter(in: hosting))
            #expect(!gutter.isHidden)
            #expect(gutter.edgeInsets.leading == 4)
            let compactWidth = gutter.frame.width
            let defaults = SourceEditorConfiguration.Layout()
            #expect(defaults.gutterLeadingPadding == 20)
            #expect(defaults.gutterMinimumDigitCount == 3)
            gutter.configureLineNumberSpacing(leadingPadding: defaults.gutterLeadingPadding,
                minimumDigitCount: defaults.gutterMinimumDigitCount)
            #expect(gutter.frame.width > compactWidth + 16)
            gutter.configureLineNumberSpacing(leadingPadding: 4, minimumDigitCount: 2)
            #expect(gutter.frame.width == compactWidth)
            try #require(window.makeFirstResponder(textView))
            textView.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
            textView.insertText(String(repeating: "\n", count: 100))
            #expect(textView.layoutManager.lineCount > 100)
            gutter.updateWidthIfNeeded()
            #expect(gutter.frame.width > compactWidth)
        }
    }

    private func findTextView(in view: NSView) -> CodeEditTextView.TextView? {
        if let textView = view as? CodeEditTextView.TextView { return textView }
        for child in view.subviews {
            if let found = findTextView(in: child) { return found }
        }
        return nil
    }

    private func findGutter(in view: NSView) -> GutterView? {
        if let gutter = view as? GutterView { return gutter }
        for child in view.subviews {
            if let found = findGutter(in: child) { return found }
        }
        return nil
    }
}
