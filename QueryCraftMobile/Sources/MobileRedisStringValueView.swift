import SwiftUI
import UIKit
import QueryCraftMobileCore

enum MobileRedisStringPreview {
    // GETRANGE uses byte offsets. Keep the next page at a UTF-8 boundary without
    // replacing bytes or mistaking a truncated scalar for a binary value.
    static func aligned(_ chunk: RedisStringChunk) -> RedisStringChunk {
        guard chunk.hasMore, chunk.value.data.count > 1, chunk.value.losslessUTF8String == nil else { return chunk }
        let data = chunk.value.data
        for count in 1...min(3, max(0, data.count - 1)) {
            let prefix = Data(data.dropLast(count))
            if String(data: prefix, encoding: .utf8) != nil {
                return .init(value: .init(data: prefix), offset: chunk.offset, totalByteCount: chunk.totalByteCount)
            }
        }
        return chunk
    }
}

struct MobileRedisKeyMenu: View {
    let model: MobileResourceModel
    var body: some View {
        Menu {
            Button("编辑值", systemImage: "square.and.pencil") { model.beginRedisEditing() }
                .disabled(!model.canEditRedis)
            Button("重命名", systemImage: "pencil") {
                if let selected = model.selected { model.beginRedisKeyRename(selected) }
            }.disabled(!model.canManageRedisKeys || model.selected == nil || model.selected?.binaryKeyData != nil)
            Button("整键 TTL", systemImage: "clock") {
                if let selected = model.selected { model.beginRedisMetadataAction(selected, action: .expiration) }
            }.disabled(!model.canManageRedisKeys || model.selected == nil || model.selected?.binaryKeyData != nil)
            Button("删除整个键", systemImage: "trash", role: .destructive) {
                if let selected = model.selected { model.beginRedisMetadataAction(selected, action: .delete) }
            }.disabled(!model.canManageRedisKeys || model.selected == nil || model.selected?.binaryKeyData != nil)
        } label: { Label("编辑", systemImage: "square.and.pencil") }
        .disabled(model.selected == nil || model.selected?.binaryKeyData != nil || model.isBackgrounded)
        .accessibilityIdentifier("editRedisKey")
    }
}

struct MobileRedisStringValueView: View {
    let model: MobileResourceModel
    let chunk: RedisStringChunk
    @State private var format = RedisValueDisplayFormat.text
    @State private var formattedJSON: String?
    @State private var formattedChunk: RedisStringChunk?
    @State private var formatter = RedisValueFormatter()
    @State private var exportsValue = false
    @State private var exportError: String?
    private var text: String? { chunk.value.losslessUTF8String }
    private var json: String? { formattedChunk == chunk ? formattedJSON : nil }
    private var effectiveFormat: RedisValueDisplayFormat { text == nil ? .hex : format == .json && json == nil ? .text : format }
    private var availableFormats: [RedisValueDisplayFormat] {
        RedisValueDisplayFormat.allCases.filter { item in
            switch item {
            case .text: text != nil
            case .json: json != nil
            case .hex: true
            }
        }
    }
    private var displayedValue: String {
        switch effectiveFormat {
        case .text: text ?? ""
        case .json: json ?? text ?? ""
        case .hex: RedisHexCodec.format(chunk.value.data)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("值显示格式", selection: Binding(get: { effectiveFormat }, set: { format = $0 })) {
                    ForEach(availableFormats) { item in
                        Text(item.title).tag(item)
                    }
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer(minLength: 8)
                Menu {
                    Button(chunk.offset == 0 && !chunk.hasMore ? "导出原始值" : "导出当前段原始字节", systemImage: "square.and.arrow.up") { exportsValue = true }
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .labelStyle(.iconOnly).accessibilityLabel("导出 String 值")
            }.padding(.horizontal, 12).frame(height: 44)
            Divider()
            MobileRedisValueText(text: displayedValue)
                .id(String(chunk.offset) + String(describing: effectiveFormat))
                .overlay(alignment: .topLeading) {
                    if chunk.value.data.isEmpty {
                        Text("空字符串").font(.callout).foregroundStyle(.secondary).padding(16).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).opacity(model.isLoadingDetails ? 1 : 0)
                    .accessibilityHidden(!model.isLoadingDetails)
                Text(model.detailError ?? (model.isLoadingDetails ? "正在加载…" : model.details?.status ?? ""))
                    .font(.caption).foregroundStyle(model.detailError == nil ? Color.secondary : .red).lineLimit(2)
                Spacer(minLength: 0)
                MobileRedisKeyMenu(model: model)
                if chunk.hasMore || model.hasPreviousDetailPage {
                    HStack(spacing: 6) {
                        Button("上一段", systemImage: "chevron.left", action: model.previous).labelStyle(.iconOnly).disabled(!model.canGoBack)
                        Button("下一段", systemImage: "chevron.right", action: model.next).labelStyle(.iconOnly).disabled(model.isLoadingDetails || !chunk.hasMore)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }.padding(.horizontal, 12).frame(height: 44)
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("redisStringValue")
        .task(id: chunk) {
            let value = chunk
            // JSON is available only for a complete value, never a valid-looking fragment.
            let formatted = if value.offset == 0 && !value.hasMore, let source = value.value.losslessUTF8String {
                await formatter.formattedJSON(from: source, maximumOutputBytes: 262_144)
            } else { nil as String? }
            guard !Task.isCancelled else { return }
            formattedJSON = formatted; formattedChunk = value
            if text == nil { format = .hex }
            else if format == .json && formatted == nil { format = .text }
        }
        .fileExporter(isPresented: $exportsValue, document: MobileRedisBinaryDocument(data: chunk.value.data), contentType: .data,
                      defaultFilename: chunk.offset == 0 && !chunk.hasMore ? "redis-value.bin" : "redis-value-part.bin") {
            if case .failure(let error) = $0, (error as NSError).code != NSUserCancelledError { exportError = error.localizedDescription }
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}

private struct MobileRedisValueText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .systemBackground
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
        view.accessibilityLabel = "Redis String 值"; view.accessibilityIdentifier = "redisStringText"
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            let selection = view.selectedRange, offset = view.contentOffset
            view.text = text
            let length = (text as NSString).length, start = min(selection.location, (text as NSString).length)
            view.selectedRange = NSRange(location: start, length: min(selection.length, length - start))
            view.layoutIfNeeded()
            view.setContentOffset(CGPoint(x: max(0, min(offset.x, view.contentSize.width - view.bounds.width)),
                                          y: max(-view.adjustedContentInset.top, min(offset.y, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom))), animated: false)
        }
        view.textColor = .label
    }
}
