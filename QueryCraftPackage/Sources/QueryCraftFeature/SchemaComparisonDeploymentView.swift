import SwiftUI

struct SchemaComparisonDeploymentView: View {
    @Bindable var deployment: SchemaComparisonDeployment
    let target: String
    let canRollback: Bool
    let previous: () -> Void
    let recompare: () -> Void
    let reviewRollback: () -> Void
    let exportLog: (String) -> Void
    @State private var selection: Int?
    private var copy: AppCopy { .current }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title).font(.title3.weight(.semibold))
                    Spacer()
                    ProgressView().controlSize(.small).frame(width: 16, height: 16).opacity(deployment.isBusy ? 1 : 0)
                    Text("\(deployment.completed) / \(deployment.total)").monospacedDigit().foregroundStyle(.secondary)
                }
                Text(target).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                SchemaComparisonProgressIndicator(fraction: deployment.total == 0 ? 0 : Double(deployment.completed) / Double(deployment.total)).frame(height: 12)
                Text(deployment.errorMessage ?? (deployment.phase == .checking ? copy.text("正在重新核对两端结构与服务器身份…", "Rechecking schema snapshots and server identities…") :
                    deployment.isBusy ? copy.text("按依赖顺序执行；停止会在当前语句结束后生效。", "Executing in dependency order. Stop takes effect after the current statement.") :
                    copy.text("执行记录已保留。MySQL DDL 会隐式提交；回退脚本仅恢复结构。", "Execution log retained. MySQL DDL implicitly commits; rollback restores structure only.")))
                    .font(.caption).foregroundStyle(deployment.errorMessage == nil ? .secondary : .primary).lineLimit(2).frame(height: 34, alignment: .topLeading)
            }.padding(20)
            Divider()
            VSplitView {
                Table(deployment.records, selection: $selection) {
                    TableColumn(copy.text("状态", "Status")) { record in
                        Label(record.error != nil ? copy.text("失败", "Failed") : record.succeeded ? copy.text("完成", "Done") : copy.text("执行中", "Running"), systemImage: record.error != nil ? "xmark.circle" : record.succeeded ? "checkmark.circle" : "clock")
                            .foregroundStyle(record.error == nil ? Color.secondary : Color.red)
                    }.width(100)
                    TableColumn("SQL") { record in Text(record.sql.replacingOccurrences(of: "\n", with: " ")).lineLimit(1) }
                    TableColumn(copy.text("耗时", "Duration")) { record in
                        Text(record.finishedAt.map { String(format: "%.2f s", $0.timeIntervalSince(record.startedAt)) } ?? "—").monospacedDigit()
                    }.width(80)
                }.tableStyle(.inset(alternatesRowBackgrounds: false)).frame(minHeight: 150)
                    .accessibilityIdentifier("schemaComparisonExecutionLog")
                if let record = deployment.records.first(where: { $0.id == selection }) {
                    VStack(spacing: 0) {
                        if let error = record.error { Text(error).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12); Divider() }
                        SchemaComparisonSQLView(ddl: record.sql)
                    }.frame(minHeight: 120)
                } else {
                    Text(copy.text("选择执行记录查看 SQL", "Select an execution record to inspect SQL")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            Divider()
            HStack {
                Button(copy.text("导出记录…", "Export Log…")) { exportLog(log) }.disabled(deployment.records.isEmpty)
                Spacer()
                if deployment.isBusy {
                    Button(deployment.isStopping ? copy.text("正在停止…", "Stopping…") : copy.text("停止", "Stop"), action: deployment.stop).disabled(deployment.isStopping)
                } else {
                    Button(copy.text("返回审核", "Back to Review"), systemImage: "chevron.left", action: previous)
                    if canRollback { Button(copy.text("审核回退…", "Review Rollback…"), action: reviewRollback).accessibilityIdentifier("schemaComparisonReviewRollback") }
                    Button(copy.text("重新比较", "Compare Again"), action: recompare).modifier(SchemaComparisonPrimaryActionStyle())
                }
            }.modifier(SchemaComparisonFooterStyle())
        }
    }
    private var title: String {
        if deployment.phase == .running && deployment.completed == deployment.total { return copy.text("正在回读核对结构", "Verifying the Schema") }
        if deployment.isRollback {
            switch deployment.phase {
            case .checking, .running: return copy.text("正在回退结构", "Rolling Back Schema")
            case .succeeded: return copy.text("结构回退完成", "Schema Rollback Complete")
            default: return copy.text("回退未完成", "Rollback Incomplete")
            }
        }
        switch deployment.phase {
        case .idle, .checking: return copy.text("部署前核对", "Preflight Check")
        case .running: return copy.text("正在部署", "Deploying")
        case .succeeded: return copy.text("部署完成，已重新读取结构", "Deployed and Schema Re-read")
        case .failed: return copy.text("部署未完成", "Deployment Incomplete")
        case .cancelled: return copy.text("部署已停止", "Deployment Stopped")
        }
    }
    private var log: String {
        "-- \(target)\n" + deployment.records.map { record in
            "-- #\(record.id + 1) \(record.startedAt.ISO8601Format()) · \(record.error ?? (record.succeeded ? "OK" : "RUNNING"))\n\(record.sql);"
        }.joined(separator: "\n\n")
    }
}
