//
//  TextView+ScrollToVisible.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/15/24.
//

import Foundation
import AppKit

extension TextView {
    fileprivate typealias Direction = TextSelectionManager.Direction
    fileprivate typealias TextSelection = TextSelectionManager.TextSelection

    /// Scrolls the upmost selection to the visible rect if `scrollView` is not `nil`.
    public func scrollSelectionToVisible() {
        guard let scrollView, textStorage.editedMask.isEmpty else {
            return
        }
        if needsLayout {
            layoutManager.layoutLines()
        }

        // Resolve the active endpoint independently of drawing. Selection backgrounds are clipped to the viewport,
        // and insertion-indicator frames can still describe the position before the latest edit.
        // Allow a bounded number of passes for the newly visible lines to refine their layout.
        var lastFrame: CGRect?
        for _ in 0..<3 {
            guard let boundingRect = selectionScrollRect(), lastFrame != boundingRect else { break }
            lastFrame = boundingRect
            if visibleRect.contains(boundingRect) { break }
            layoutManager.layoutLines()
            scrollView.contentView.scrollToVisible(boundingRect)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        selectionManager.updateSelectionViews()
        needsDisplay = true
    }

    func selectionScrollRect() -> CGRect? {
        guard textStorage.editedMask.isEmpty,
              let selection = getSelection(),
              var rect = layoutManager.rectForOffset(offsetNotPivot(selection)) else { return nil }
        // The gutter and minimap float over the document, so a caret behind them is not actually visible.
        rect.origin.x -= layoutManager.edgeInsets.left
        rect.size.width = max(rect.width, 1) + layoutManager.edgeInsets.horizontal
        return rect
    }

    /// Scrolls the view to the specified range.
    ///
    /// - Parameters:
    ///   - range: The range to scroll to.
    ///   - center: A flag that determines if the range should be centered in the view. Defaults to `true`.
    ///
    /// If `center` is `true`, the range will be centered in the visible area.
    /// If `center` is `false`, the range will be aligned at the top-left of the view.
    public func scrollToRange(_ range: NSRange, center: Bool = true) {
        guard let scrollView else { return }

        guard let boundingRect = layoutManager.rectForOffset(range.location) else { return }

        // Check if the range is already visible
        if visibleRect.contains(boundingRect) {
            return // No scrolling needed
        }

        // Calculate the target offset based on the center flag
        let targetOffset: CGPoint
        if center {
            targetOffset = CGPoint(
                x: max(boundingRect.midX - visibleRect.width / 2, 0),
                y: max(boundingRect.midY - visibleRect.height / 2, 0)
            )
        } else {
            targetOffset = CGPoint(
                x: max(boundingRect.origin.x, 0),
                y: max(boundingRect.origin.y, 0)
            )
        }

        var lastFrame: CGRect = .zero

        // Set a timeout to avoid an infinite loop
        let timeout: TimeInterval = 0.5
        let startTime = Date()

        // Adjust layout until stable
        while let newRect = layoutManager.rectForOffset(range.location),
              lastFrame != newRect,
              Date().timeIntervalSince(startTime) < timeout {
            lastFrame = newRect
            layoutManager.layoutLines()
            selectionManager.updateSelectionViews()
            selectionManager.drawSelections(in: visibleRect)
        }

        // Scroll to make the range appear at the desired position
        if lastFrame != .zero {
            let animated = false // feature flag
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15 // Adjust duration as needed
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    scrollView.contentView.animator().setBoundsOrigin(targetOffset)
                }
            } else {
                scrollView.contentView.scroll(to: targetOffset)
            }
        }
    }

    /// Get the selection that should be scrolled to visible for the current text selection.
    /// - Returns: The the selection to scroll to.
    private func getSelection() -> TextSelection? {
        selectionManager
            .textSelections
            .sorted(by: { $0.range.max > $1.range.max }) // Get the lowest one.
            .first
    }

    /// Returns the offset that isn't the pivot of the selection.
    /// - Parameter selection: The selection to use.
    /// - Returns: The offset suitable for scrolling to.
    private func offsetNotPivot(_ selection: TextSelection) -> Int {
        guard let pivot = selection.pivot else {
            return selection.range.location
        }
        if selection.range.location == pivot {
            return selection.range.max
        } else {
            return selection.range.location
        }
    }
}
