//
//  CodeSuggestionLabelView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/24/25.
//

import AppKit
import SwiftUI

struct CodeSuggestionLabelView: View {
    static let HORIZONTAL_PADDING: CGFloat = 13
    static let ICON_TEXT_SPACING: CGFloat = 8
    static let METADATA_SPACING: CGFloat = 12
    static let ICON_WIDTH_PADDING: CGFloat = 4

    let suggestion: CodeSuggestionEntry
    let labelColor: NSColor
    let secondaryLabelColor: NSColor
    let font: NSFont

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            suggestion.image
                .font(.system(size: font.pointSize + 2))
                .foregroundStyle(
                    suggestion.deprecated ? .gray : suggestion.imageColor
                )
                .frame(width: font.pointSize + Self.ICON_WIDTH_PADDING)
                .padding(.trailing, Self.ICON_TEXT_SPACING)

            Text(suggestion.label)
                .foregroundStyle(
                    suggestion.deprecated
                        ? Color(secondaryLabelColor)
                        : Color(labelColor)
                )
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: Self.METADATA_SPACING)

            if let detail = suggestion.detail {
                Text(detail)
                    .foregroundStyle(Color(secondaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
            }

            // Right side indicators
            if suggestion.deprecated {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: font.pointSize + 2))
                    .foregroundStyle(Color(labelColor), Color(secondaryLabelColor))
            }
        }
        .font(Font(font))
        .padding(.vertical, 3)
        .padding(.horizontal, Self.HORIZONTAL_PADDING)
        .buttonStyle(PlainButtonStyle())
    }
}
