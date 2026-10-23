import Foundation
import Observation
import QueryCraftMobileCore
import QueryCraftMobileTransport

@MainActor @Observable final class MobileQueryResultState: Identifiable {
    enum Phase { case waiting, running, completed, failed, stopped, skipped }
    let id = UUID()
    let viewport = MobileGridViewport()
    var isPreviousBatch = false
    var statement: SQLExecutionStatement?
    var phase: Phase = .waiting
    var status = "等待执行"
    var errorMessage: String?
    var lastExecutedRange: SQLSourceRange? = nil
    var result: CDatabaseQueryResult? = nil
    var preview: CDatabaseQueryPreview? = nil
    var lastExecutedSQL: String? = nil
    var lastExecutedDatabase: String? = nil
    var elapsed: Duration? = nil
    var resultRevision: UUID = UUID()
    var resultID: UUID = UUID()
    var editing: MobileTableChanges? = nil
    var editingPage: MobileTableSnapshot? = nil
    var editingMessage: String? = nil
    var lastExecutedConfiguration: MariaDBTransportConfiguration? = nil
    var requiresResultReload: Bool = false
    var cache: MobileCachedQueryResult?
    var cachedRowCount = 0
    var cacheOffset = 0
    var previousCacheOffsets: [Int] = []
    var cacheComplete = false
    var hasBinaryValues = false
    init(statement: SQLExecutionStatement? = nil) { self.statement = statement }
    var title: String {
        guard let statement else { return "查询结果" }
        let phaseName: String = switch phase {
        case .waiting: "等待"; case .running: "执行中"; case .completed: "完成"
        case .failed: "失败"; case .stopped: "已取消"; case .skipped: "未执行"
        }
        return (isPreviousBatch ? "上次" : "") + "结果 \(statement.index + 1) · " + phaseName
    }
}
