//
//  EmphasisStyle.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 3/31/25.
//

import AppKit

/// Defines the style of emphasis to apply to text ranges
public enum EmphasisStyle: Equatable {
    /// Standard emphasis with background color
    case standard
    /// Underline emphasis with a line color
    case underline(color: NSColor)
    /// Outline emphasis with a border color
    case outline(color: NSColor, fill: Bool = false)
    /// Plain background fill with the given color.
    ///
    /// Unlike ``standard`` this never draws a duplicate text layer, never flashes or pops, and never draws
    /// shadows. Useful for selection-like highlights.
    case fill(color: NSColor, borderColor: NSColor? = nil)

    public static func == (lhs: EmphasisStyle, rhs: EmphasisStyle) -> Bool {
        switch (lhs, rhs) {
        case (.standard, .standard):
            return true
        case (.underline(let lhsColor), .underline(let rhsColor)):
            return lhsColor == rhsColor
        case let (.outline(lhsColor, lhsFill), .outline(rhsColor, rhsFill)):
            return lhsColor == rhsColor && lhsFill == rhsFill
        case let (.fill(lhsColor, lhsBorder), .fill(rhsColor, rhsBorder)):
            return lhsColor == rhsColor && lhsBorder == rhsBorder
        default:
            return false
        }
    }

    var shapeRadius: CGFloat {
        switch self {
        case .standard:
            4
        case .underline:
            0
        case .fill, .outline:
            2.5
        }
    }
}
