import SwiftUI

struct WorkspaceElasticsearchResponseDetailsView: View {
    let details: WorkspaceElasticsearchResponseDetails
    let canLocateError: Bool
    let locateError: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(AppCopy.current.text("查询详情", "Query Details")).font(.headline)
                if let total = details.totalHits {
                    LabeledContent(AppCopy.current.text("总命中数", "Total Hits"),
                        value: (details.totalIsLowerBound ? "≥ " : "") + total)
                }
                if let count = details.returnedHits {
                    LabeledContent(AppCopy.current.text("服务器返回文档", "Returned Documents"), value: String(count))
                }
                if let count = details.displayedRows {
                    LabeledContent(AppCopy.current.text("表格展示行数", "Displayed Rows"), value: String(count))
                }
                if let took = details.tookMilliseconds {
                    LabeledContent(AppCopy.current.text("ES 执行耗时", "ES Execution Time"), value: "\(took) ms")
                }
                if let timedOut = details.timedOut {
                    LabeledContent(AppCopy.current.text("查询超时", "Query Timed Out"),
                        value: timedOut ? AppCopy.current.text("是", "Yes") : AppCopy.current.text("否", "No"))
                }
                if details.totalShards != nil || details.successfulShards != nil || details.failedShards != nil {
                    Divider()
                    shardValue(AppCopy.current.text("分片总数", "Total Shards"), details.totalShards)
                    shardValue(AppCopy.current.text("成功分片", "Successful Shards"), details.successfulShards)
                    shardValue(AppCopy.current.text("跳过分片", "Skipped Shards"), details.skippedShards)
                    shardValue(AppCopy.current.text("失败分片", "Failed Shards"), details.failedShards)
                }
                if let failure = details.failureMessage {
                    Divider()
                    Text(failure).foregroundStyle(.red)
                }
                ForEach(Array(details.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(diagnostic.message)
                        if let line = diagnostic.line, let column = diagnostic.column {
                            Text(AppCopy.current.text("服务器报告位置：第 \(line) 行，第 \(column) 列",
                                "Server-reported position: line \(line), column \(column)"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if details.diagnostics.contains(where: { $0.documentRange != nil }) {
                    Button(AppCopy.current.text("定位错误", "Locate Error"), action: locateError)
                        .disabled(!canLocateError)
                    if !canLocateError {
                        Text(AppCopy.current.text("请求已修改，请重新执行后定位。",
                            "The request has changed. Run it again before locating the error."))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(16)
        }
        .frame(width: 480, height: 360)
    }

    private func shardValue(_ label: String, _ value: Int?) -> some View {
        LabeledContent(label, value: value.map(String.init) ?? "—")
    }
}
