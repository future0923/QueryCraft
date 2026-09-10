//
//  TextView+Mouse.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/19/23.
//

import AppKit

extension TextView {
    override public func mouseDown(with event: NSEvent) {
        // Set cursor
        let mouseDownLocation = convert(event.locationInWindow, from: nil)
        guard isSelectable,
              event.type == .leftMouseDown,
              let offset = layoutManager.textOffsetAtPoint(mouseDownLocation) else {
            super.mouseDown(with: event)
            return
        }

        if let content = layoutManager.contentRun(at: offset),
           case let .attachment(attachment) = content.data, event.clickCount < 3 {
            handleAttachmentClick(event: event, offset: offset, attachment: attachment)
            return
        }

        mouseDragAnchor = mouseDownLocation
        mouseDragAnchorOffset = offset

        switch event.clickCount {
        case 1:
            handleSingleClick(event: event, offset: offset)
        case 2:
            handleDoubleClick(event: event)
        case 3:
            handleTripleClick(event: event)
        default:
            break
        }

        mouseDragPublishedRanges = selectionManager.textSelections.map(\.range)
        mouseDragSelectionDidChange = false
    }

    /// Single click, if control-shift we add a cursor
    /// if shift, we extend the selection to the click location
    /// else we set the cursor
    fileprivate func handleSingleClick(event: NSEvent, offset: Int) {
        cursorSelectionMode = .character

        guard isEditable else {
            super.mouseDown(with: event)
            return
        }
        let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if eventFlags == [.control, .shift] {
            unmarkText()
            selectionManager.addSelectedRange(NSRange(location: offset, length: 0))
        } else if eventFlags.contains(.shift) {
            unmarkText()
            shiftClickExtendSelection(to: offset)
        } else {
            selectionManager.setSelectedRange(NSRange(location: offset, length: 0))
            unmarkTextIfNeeded()
        }
    }

    fileprivate func handleDoubleClick(event: NSEvent) {
        cursorSelectionMode = .word

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        selectWord(nil)
    }

    fileprivate func handleTripleClick(event: NSEvent) {
        cursorSelectionMode = .line

        guard !event.modifierFlags.contains(.shift) else {
            super.mouseDown(with: event)
            return
        }
        unmarkText()
        selectLine(nil)
    }

    fileprivate func handleAttachmentClick(event: NSEvent, offset: Int, attachment: AnyTextAttachment) {
        switch event.clickCount {
        case 1:
            selectionManager.setSelectedRange(attachment.range)
        case 2:
            performAttachmentAction(attachment: attachment)
        default:
            break
        }
    }

    func performAttachmentAction(attachment: AnyTextAttachment) {
        let action = attachment.attachment.attachmentAction()
        switch action {
        case .none:
            return
        case .discard:
            layoutManager.attachments.remove(atOffset: attachment.range.location)
            selectionManager.setSelectedRange(NSRange(location: attachment.range.location, length: 0))
        case let .replace(text):
            replaceCharacters(in: attachment.range, with: text)
        }
    }

    override public func mouseUp(with event: NSEvent) {
        if mouseDragSelectionDidChange {
            selectionManager.finishMouseDragSelection(
                notifyObservers: selectionManager.textSelections.map(\.range) != mouseDragPublishedRanges
            )
            setNeedsDisplay(visibleRect)
        }
        mouseDragAnchor = nil
        mouseDragAnchorOffset = nil
        mouseDragPublishedRanges = nil
        mouseDragSelectionDidChange = false
        super.mouseUp(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard !(inputContext?.handleEvent(event) ?? false) && isSelectable && !isDragging else {
            return
        }

        var pointerLocation = convert(event.locationInWindow, from: nil)
        var selectionBounds = visibleRect.intersection(bounds)
        guard !selectionBounds.isNull, !selectionBounds.isEmpty else { return }

        if !selectionBounds.contains(pointerLocation),
           shouldAutoscroll(pointerLocation, beyond: selectionBounds) {
            autoscroll(with: event)
            pointerLocation = convert(event.locationInWindow, from: nil)
            selectionBounds = visibleRect.intersection(bounds)
            guard !selectionBounds.isNull, !selectionBounds.isEmpty else { return }
        }

        let textHitMinX = min(
            selectionBounds.maxX,
            max(selectionBounds.minX, layoutManager.edgeInsets.left)
        )
        let textHitBounds = CGRect(
            x: textHitMinX,
            y: selectionBounds.minY,
            width: selectionBounds.maxX - textHitMinX,
            height: selectionBounds.height
        )
        let locationInView = CGPoint(
            x: max(textHitBounds.minX, min(pointerLocation.x, textHitBounds.maxX)),
            y: max(selectionBounds.minY, min(pointerLocation.y, selectionBounds.maxY))
        )

        if mouseDragAnchor == nil || mouseDragAnchorOffset == nil {
            mouseDragAnchor = pointerLocation
            mouseDragAnchorOffset = layoutManager.textOffsetAtPoint(pointerLocation)
            super.mouseDragged(with: event)
        } else {
            guard let mouseDragAnchor,
                  let startPosition = mouseDragAnchorOffset,
                  let endPosition = layoutManager.textOffsetAtPoint(locationInView) else {
                return
            }

            let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifierFlags.contains(.option) {
                dragColumnSelection(mouseDragAnchor: mouseDragAnchor, locationInView: locationInView)
                setNeedsDisplay(visibleRect)
            } else {
                guard dragSelection(startPosition: startPosition, endPosition: endPosition) else { return }
                mouseDragSelectionDidChange = true
                setNeedsDisplay(visibleRect)
            }
        }
    }

    private func shouldAutoscroll(_ pointer: CGPoint, beyond visibleBounds: CGRect) -> Bool {
        let tolerance: CGFloat = 1
        return (pointer.x < visibleBounds.minX && visibleBounds.minX > bounds.minX + tolerance)
        || (pointer.x > visibleBounds.maxX && visibleBounds.maxX < bounds.maxX - tolerance)
        || (pointer.y < visibleBounds.minY && visibleBounds.minY > bounds.minY + tolerance)
        || (pointer.y > visibleBounds.maxY && visibleBounds.maxY < bounds.maxY - tolerance)
    }

    /// Extends the current selection to the offset. Only used when the user shift-clicks a location in the document.
    ///
    /// If the offset is within the selection, trims the selection from the nearest edge (start or end) towards the
    /// clicked offset.
    /// Otherwise, extends the selection to the clicked offset.
    ///
    /// - Parameter offset: The offset clicked on.
    fileprivate func shiftClickExtendSelection(to offset: Int) {
        // Use the last added selection, this is behavior copied from Xcode.
        guard var selectedRange = selectionManager.textSelections.last?.range else { return }
        if selectedRange.contains(offset) {
            if offset - selectedRange.location <= selectedRange.max - offset {
                selectedRange.length -= offset - selectedRange.location
                selectedRange.location = offset
            } else {
                selectedRange.length -= selectedRange.max - offset
            }
        } else {
            selectedRange.formUnion(NSRange(
                start: min(offset, selectedRange.location),
                end: max(offset, selectedRange.max)
            ))
        }
        selectionManager.setSelectedRange(selectedRange)
        setNeedsDisplay()
    }

    // MARK: - Drag Selection

    @discardableResult
    private func dragSelection(startPosition: Int, endPosition: Int) -> Bool {
        let range: NSRange
        switch cursorSelectionMode {
        case .character:
            range = NSRange(
                location: min(startPosition, endPosition),
                length: max(startPosition, endPosition) - min(startPosition, endPosition)
            )

        case .word:
            let startWordRange = findWordBoundary(at: startPosition)
            let endWordRange = findWordBoundary(at: endPosition)

            range = NSRange(
                location: min(startWordRange.location, endWordRange.location),
                length: max(startWordRange.location + startWordRange.length,
                            endWordRange.location + endWordRange.length) -
                min(startWordRange.location, endWordRange.location)
            )

        case .line:
            let startLineRange = findLineBoundary(at: startPosition)
            let endLineRange = findLineBoundary(at: endPosition)

            range = NSRange(
                location: min(startLineRange.location, endLineRange.location),
                length: max(startLineRange.location + startLineRange.length,
                            endLineRange.location + endLineRange.length) -
                min(startLineRange.location, endLineRange.location)
            )
        }

        return selectionManager.updateSelectedRangeDuringMouseDrag(range)
    }

    private func dragColumnSelection(mouseDragAnchor: CGPoint, locationInView: CGPoint) {
        selectColumns(betweenPointA: mouseDragAnchor, pointB: locationInView)
    }
}
