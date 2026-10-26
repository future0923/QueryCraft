import SwiftUI
import QueryCraftMobileCore

/// One member remains one Form row. Inline actions must never become the
/// primary action for the whole row (including its text fields).
struct MobileRedisMemberRow: View {
    @Binding var row: RedisKeyEditableRow
    let type: RedisKeyType
    var creationIndex: Int? = nil
    var supportsFieldExpiration = false
    var isSelected = false
    var select: (() -> Void)? = nil
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let select {
                    Button(action: select) {
                        Text(Image(systemName: isSelected ? "checkmark.circle.fill" : "circle"))
                            .font(.body).frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(isSelected ? "取消选择成员" : "选择成员")
                        .accessibilityIdentifier("redisMemberSelection-" + row.id.uuidString)
                }
                if type == .list {
                    Text(row.originalIndex.map { "位置 \($0)" } ?? creationIndex.map { "位置 \($0)" }
                         ?? (row.insertionEdge == .head ? "新增到头部" : "新增到尾部"))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(minWidth: 64, idealWidth: 110, maxWidth: 160, alignment: .leading).padding(.vertical, 8)
                } else if type == .set {
                    Text("成员").foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    TextField(type == .hash ? "字段" : "成员", text: $row.firstValue)
                        .multilineTextAlignment(.leading)
                        .frame(minWidth: 64, idealWidth: 110, maxWidth: 160, alignment: .leading).padding(.vertical, 8)
                        .disabled(row.isBinaryReadOnly)
                }
                if type == .set {
                    TextField("成员", text: $row.firstValue)
                        .multilineTextAlignment(.trailing).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .disabled(row.isBinaryReadOnly)
                } else {
                    TextField(type == .sortedSet ? "分数" : "值", text: $row.secondValue, axis: .vertical).lineLimit(1...4)
                        .multilineTextAlignment(.trailing).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .disabled(row.isBinaryReadOnly)
                }
                Button(role: row.isDeleted ? nil : .destructive, action: remove) {
                    Text(Image(systemName: row.isDeleted ? "arrow.uturn.backward" : "trash"))
                        .font(.body).frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(row.isDeleted ? "撤销删除" : "删除成员")
                    .accessibilityIdentifier("redisMemberRemove-" + row.id.uuidString)
                    .disabled(row.isBinaryReadOnly)
            }
            if type == .hash, supportsFieldExpiration {
                LabeledContent("字段 TTL") {
                    TextField("永久", text: $row.thirdValue).keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing).disabled(row.isBinaryReadOnly)
                        .accessibilityLabel("字段 TTL（毫秒，留空为永久）")
                        .accessibilityIdentifier("redisMemberTTL-" + row.id.uuidString)
                }
            }
            if row.isBinaryReadOnly {
                Text("二进制成员保留原始字节，暂不支持移动端修改。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .buttonStyle(.borderless)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .opacity(row.isDeleted ? 0.5 : 1)
    }
}
