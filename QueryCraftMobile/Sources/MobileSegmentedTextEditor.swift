import SwiftUI

struct MobileSegmentedTextEditor: View {
    @Binding var text: String
    let accessibilityIdentifier: String
    @State private var offset = 0
    @State private var history: [Int] = []
    private var segmented: Bool { text.utf8.count > 65_536 }
    private var range: MobileTextSegment { .range(in: text, offset: offset) }
    var body: some View {
        VStack(spacing: 8) {
            if segmented {
                HStack {
                    Button("上一段") { if let prior = history.popLast() { offset = prior } }.disabled(history.isEmpty)
                    Spacer(); Text("展示偏移 \(offset)").font(.caption); Spacer()
                    Button("下一段") {
                        let current = range; history.append(current.offset)
                        offset = text.utf8.distance(from: text.utf8.startIndex, to: current.end)
                    }.disabled(range.end == text.utf8.endIndex)
                }
                Text("长输入分段展示，执行时使用完整命令。").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: Binding(get: { segmented ? range.text(in: text) : text }, set: { value in
                text = segmented ? range.replacing(in: text, with: value) : value
                if !segmented { offset = 0; history = [] }
            })).font(.system(.body, design: .monospaced)).frame(minHeight: 130)
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
