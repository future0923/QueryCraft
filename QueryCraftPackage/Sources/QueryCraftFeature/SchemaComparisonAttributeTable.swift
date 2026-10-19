import SwiftUI

struct SchemaComparisonAttributeTable: View {
    let differences: [SchemaComparisonDifference]
    private var copy: AppCopy { .current }
    private struct Row: Identifiable {
        let id: String
        let object: String
        let property: String
        let source: String
        let target: String
    }
    private var rows: [Row] {
        differences.filter { $0.status != .equal }.flatMap { difference in
            let attributes: [SchemaComparisonAttribute]
            if !difference.attributes.isEmpty { attributes = difference.attributes }
            else if difference.object == "table" {
                attributes = [.init(key: "presence", source: difference.source.isEmpty ? "—" : copy.text("存在", "Present"),
                                    target: difference.target.isEmpty ? "—" : copy.text("存在", "Present"))]
            } else {
                attributes = [.init(key: "definition", source: difference.source.isEmpty ? "—" : difference.source,
                                    target: difference.target.isEmpty ? "—" : difference.target)]
            }
            return attributes.map { attribute in
                Row(id: difference.id + "\0" + attribute.key,
                    object: difference.object == "table" ? difference.table : difference.displayName,
                    property: difference.operationTitle + " · " + attribute.title, source: attribute.source, target: attribute.target)
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(copy.text("以源为准，目标调整为源的结构", "Target changes to match the source"))
                Spacer()
                Text(copy.text("\(differences.filter { $0.status != .equal }.count) 项差异 · \(differences.filter { $0.sqlForReview != nil }.count) 项可导出",
                               "\(differences.filter { $0.status != .equal }.count) changes · \(differences.filter { $0.sqlForReview != nil }.count) exportable"))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 30)
            Table(rows) {
                TableColumn(copy.text("对象", "Object"), value: \.object).width(min: 110, ideal: 150, max: 220)
                TableColumn(copy.text("变化", "Change"), value: \.property).width(min: 100, ideal: 130, max: 200)
                TableColumn(copy.text("源（期望）", "Source (Desired)")) { row in
                    Text(row.source).lineLimit(2).help(row.source)
                }
                TableColumn(copy.text("目标（当前）", "Target (Current)")) { row in
                    Text(row.target).lineLimit(2).help(row.target)
                }
            }.tableStyle(.inset(alternatesRowBackgrounds: false))
                .accessibilityIdentifier("schemaComparisonAttributes")
                .overlay {
                    if rows.isEmpty {
                        Text(differences.isEmpty ? copy.text("选择对象查看具体变化", "Select an object to inspect changes") :
                            copy.text("定义一致", "Definitions match")).foregroundStyle(.secondary)
                    }
                }
        }
    }
}
