//
//  LineFoldCalculator.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/9/25.
//

import AppKit
import CodeEditTextView

/// `LineFoldCalculator` receives text edits and rebuilds fold regions asynchronously.
///
/// This is an actor, all methods and modifications happen in isolation in it's async region. All text requests are
/// marked `@MainActor` for safety.
actor LineFoldCalculator {
    weak var foldProvider: LineFoldProvider?
    weak var controller: TextViewController?

    struct Result: Sendable {
        let revision: UInt64
        let storage: LineFoldStorage
    }

    var valueStream: AsyncStream<Result>

    private var valueStreamContinuation: AsyncStream<Result>.Continuation
    private var textChangedTask: Task<Void, Never>?

    /// Create a new calculator object that listens to a given stream for text changes.
    /// - Parameters:
    ///   - foldProvider: The object to use to calculate fold regions.
    ///   - controller: The text controller to use for text and attachment fetching.
    ///   - textChangedStream: A stream of text changes, received as the document is edited.
    init(
        foldProvider: LineFoldProvider,
        controller: TextViewController,
        textChangedStream: AsyncStream<Void>
    ) {
        // This could be grabbed from the controller, but Swift 6 doesn't like that (concurrency safety)
        self.foldProvider = foldProvider
        self.controller = controller
        (valueStream, valueStreamContinuation) = AsyncStream<Result>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task { [weak self] in await self?.listenToTextChanges(textChangedStream: textChangedStream) }
    }

    deinit {
        textChangedTask?.cancel()
    }

    /// Sets up an attached task to listen to values on a stream of text changes.
    /// - Parameter textChangedStream: A stream of text changes.
    private func listenToTextChanges(textChangedStream: AsyncStream<Void>) {
        textChangedTask = Task { [weak self] in
            for await _ in textChangedStream {
                guard !Task.isCancelled, let self else { break }
                await self.buildFoldsForDocument()
            }
        }
    }

    /// Build out the folds for the entire document.
    ///
    /// For each line in the document, find the indentation level using the ``levelProvider``. At each line, if the
    /// indent increases from the previous line, we start a new fold. If it decreases we end the fold we were in.
    private func buildFoldsForDocument() async {
        guard let controller = self.controller, let foldProvider = self.foldProvider else { return }
        guard let revision = await controller.gutterView.foldingRibbon.model?.revision else { return }
        let documentRange = await controller.textView.documentRange
        var foldCache: [LineFoldStorage.RawFold] = []
        // Depth: Open range
        var openFolds: [Int: LineFoldStorage.RawFold] = [:]
        var currentDepth: Int = 0
        let lineIterator = await ChunkedLineIterator(
            controller: controller,
            foldProvider: foldProvider,
            revision: revision,
            textIterator: await controller.textView.layoutManager.lineStorage.makeIterator()
        )

        for await lineChunk in lineIterator {
            guard !Task.isCancelled else { return }
            for lineInfo in lineChunk {
                // Start a new fold, going deeper to a new depth.
                if lineInfo.depth > currentDepth {
                    let newFold = LineFoldStorage.RawFold(
                        depth: lineInfo.depth,
                        range: lineInfo.rangeIndice..<lineInfo.rangeIndice
                    )
                    openFolds[newFold.depth] = newFold
                } else if lineInfo.depth < currentDepth {
                    // End open folds > received depth
                    for openFold in openFolds.values.filter({ $0.depth > lineInfo.depth }) {
                        openFolds.removeValue(forKey: openFold.depth)
                        foldCache.append(
                            LineFoldStorage.RawFold(
                                depth: openFold.depth,
                                range: openFold.range.lowerBound..<lineInfo.rangeIndice
                            )
                        )
                    }
                }

                currentDepth = lineInfo.depth
            }
            await Task.yield()
        }

        guard await controller.gutterView.foldingRibbon.model?.revision == revision else { return }

        // Clean up any hanging folds.
        for fold in openFolds.values {
            foldCache.append(
                LineFoldStorage.RawFold(
                    depth: fold.depth,
                    range: fold.range.lowerBound..<documentRange.length
                )
            )
        }

        await yieldNewStorage(newFolds: foldCache, controller: controller, documentRange: documentRange, revision: revision)
    }

    /// Yield a new storage value on the value stream using a new set of folds.
    /// - Parameters:
    ///   - newFolds: The new folds to yield with the storage value.
    ///   - controller: The text controller used for range and attachment fetching.
    ///   - documentRange: The total range of the current document.
    private func yieldNewStorage(
        newFolds: [LineFoldStorage.RawFold],
        controller: TextViewController,
        documentRange: NSRange,
        revision: UInt64
    ) async {
        let attachments = await controller.textView.layoutManager.attachments
            .getAttachmentsOverlapping(documentRange)
            .compactMap { attachmentBox -> LineFoldStorage.DepthStartPair? in
                guard let attachment = attachmentBox.attachment as? LineFoldPlaceholder else {
                    return nil
                }
                return LineFoldStorage.DepthStartPair(depth: attachment.fold.depth, start: attachmentBox.range.location)
            }

        let storage = LineFoldStorage(
            documentLength: newFolds.max(
                by: { $0.range.upperBound < $1.range.upperBound }
            )?.range.upperBound ?? documentRange.length,
            folds: newFolds.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }),
            collapsedRanges: Set(attachments)
        )
        valueStreamContinuation.yield(Result(revision: revision, storage: storage))
    }

    /// Asynchronously gets more line information from the fold provider.
    /// Runs on the main thread so all text-related calculations are safe with the main text storage.
    ///
    /// Has to be an `AsyncSequence` so it can be main actor isolated.
    @MainActor
    struct ChunkedLineIterator: AsyncSequence, AsyncIteratorProtocol {
        var controller: TextViewController
        var foldProvider: LineFoldProvider
        let revision: UInt64
        private var previousDepth: Int = 0
        var textIterator: TextLineStorage<TextLine>.TextLineStorageIterator

        init(
            controller: TextViewController,
            foldProvider: LineFoldProvider,
            revision: UInt64,
            textIterator: TextLineStorage<TextLine>.TextLineStorageIterator
        ) {
            self.controller = controller
            self.foldProvider = foldProvider
            self.revision = revision
            self.textIterator = textIterator
        }

        nonisolated func makeAsyncIterator() -> ChunkedLineIterator {
            self
        }

        mutating func next() -> [LineFoldProviderLineInfo]? {
            // Native line iterators must not outlive the text revision they
            // were created for (e.g. when switching documents mid-calculation).
            guard !Task.isCancelled,
                  controller.gutterView.foldingRibbon.model?.revision == revision else { return nil }
            var results: [LineFoldProviderLineInfo] = []
            var count = 0
            var previousDepth: Int = previousDepth
            while count < 50, let linePosition = textIterator.next() {
                let foldInfo = foldProvider.foldLevelAtLine(
                    lineNumber: linePosition.index,
                    lineRange: linePosition.range,
                    previousDepth: previousDepth,
                    controller: controller
                )
                results.append(contentsOf: foldInfo)
                count += 1
                previousDepth = foldInfo.max(by: { $0.depth < $1.depth })?.depth ?? previousDepth
            }
            if results.isEmpty && count == 0 {
                return nil
            }
            self.previousDepth = previousDepth
            return results
        }
    }
}
