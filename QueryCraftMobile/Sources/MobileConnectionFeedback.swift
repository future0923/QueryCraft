import Foundation
import QueryCraftMobileTransport

/// The server response, rather than reachability, determines whether a read succeeded.
enum MobileConnectionFeedback {
    static let paused = "读取已暂停，内容已保留。点顶部刷新重试。"
    static let interruptedWrite = "提交已中断，暂存改动已保留；本次未确认提交成功。请检查错误后手动重试。"

    static func reading(_ error: any Error) -> String {
        if isConnectionFailure(error) {
            return "连接失败，内容已保留。检查网络后点顶部刷新重试。\n" + error.localizedDescription
        }
        return error.localizedDescription
    }

    static func writing(_ error: any Error) -> String {
        if error is CancellationError { return interruptedWrite }
        if isConnectionFailure(error) {
            return "连接失败，改动已保留。检查网络后手动提交；未自动重试。\n" + error.localizedDescription
        }
        return error.localizedDescription
    }

    private static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? CDatabaseClientError else { return false }
        return [2002, 2003, 2005, 2006, 2013, 2055].contains(error.code)
            || error.sqlState?.hasPrefix("08") == true
    }
}
