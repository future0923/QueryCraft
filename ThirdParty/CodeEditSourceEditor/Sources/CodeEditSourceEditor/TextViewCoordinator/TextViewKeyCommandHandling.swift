//
//  TextViewKeyCommandHandling.swift
//  CodeEditSourceEditor
//

import CodeEditTextView

public enum TextViewKeyCommand: Sendable {
    case commandReturn
    case commandShiftReturn
    case commandI
    case commandS
    case commitTransaction
    case rollbackTransaction
    case escape
}

@MainActor
public protocol TextViewKeyCommandHandling: AnyObject {
    func handleTextViewKeyCommand(
        _ command: TextViewKeyCommand,
        textView: TextView
    ) -> Bool
}
