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
    case tab
    case backtab
    case escape
}

@MainActor
public protocol TextViewKeyCommandHandling: AnyObject {
    func handleTextViewKeyCommand(
        _ command: TextViewKeyCommand,
        textView: TextView
    ) -> Bool
}

/// 协调器可实现此协议，在补全窗口等按键消费方处理按键之前，
/// 以无副作用的方式声明自己是否会接管该按键。
@MainActor
public protocol TextViewKeyCommandClaiming: AnyObject {
    func claimsTextViewKeyCommand(
        _ command: TextViewKeyCommand,
        textView: TextView
    ) -> Bool
}
