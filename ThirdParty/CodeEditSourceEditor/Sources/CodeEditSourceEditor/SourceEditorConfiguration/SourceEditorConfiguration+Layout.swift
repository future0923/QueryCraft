//
//  SourceEditorConfiguration+Layout.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/16/25.
//

import AppKit

extension SourceEditorConfiguration {
    public struct Layout: Equatable {
        /// The distance to overscroll the editor by, as a multiple of the visible editor height.
        public var editorOverscroll: CGFloat = 0

        /// Insets to use to offset the content in the enclosing scroll view. Leave as `nil` to let the scroll view
        /// automatically adjust content insets.
        public var contentInsets: NSEdgeInsets?

        /// An additional amount to inset the text of the editor by.
        public var additionalTextInsets: NSEdgeInsets?

        /// Space before the widest line number, independent of the editor's outer insets.
        public var gutterLeadingPadding: CGFloat = 20

        /// Minimum number of digits reserved by the line number gutter.
        public var gutterMinimumDigitCount: Int = 3

        public init(
            editorOverscroll: CGFloat = 0,
            contentInsets: NSEdgeInsets? = nil,
            additionalTextInsets: NSEdgeInsets? = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0),
            gutterLeadingPadding: CGFloat = 20,
            gutterMinimumDigitCount: Int = 3
        ) {
            self.editorOverscroll = editorOverscroll
            self.contentInsets = contentInsets
            self.additionalTextInsets = additionalTextInsets
            self.gutterLeadingPadding = gutterLeadingPadding
            self.gutterMinimumDigitCount = gutterMinimumDigitCount
        }

        @MainActor
        func didSetOnController(controller: TextViewController, oldConfig: Layout?) {
            if oldConfig?.gutterLeadingPadding != gutterLeadingPadding
                || oldConfig?.gutterMinimumDigitCount != gutterMinimumDigitCount {
                controller.gutterView.configureLineNumberSpacing(
                    leadingPadding: gutterLeadingPadding, minimumDigitCount: gutterMinimumDigitCount
                )
            }
            if oldConfig?.editorOverscroll != editorOverscroll {
                controller.textView.overscrollAmount = editorOverscroll
            }

            if oldConfig?.contentInsets != contentInsets {
                controller.updateContentInsets()
            }

            if oldConfig?.additionalTextInsets != additionalTextInsets {
                controller.styleScrollView()
            }
        }
    }
}
