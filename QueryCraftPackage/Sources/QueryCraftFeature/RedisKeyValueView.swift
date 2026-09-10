import SwiftUI

struct RedisKeyValueView: View {
    let keyType: RedisKeyType
    let snapshot: RedisKeyValueSnapshot

    @State private var selectedFormat = RedisValueDisplayFormat.text
    @State private var formattedJSON: String?
    @State private var formatter = RedisValueFormatter()

    var body: some View {
        VStack(spacing: 0) {
            if let scalarValue {
                RedisScalarValueToolbar(
                    selectedFormat: $selectedFormat,
                    allowsJSON: formattedJSON != nil
                )
                Divider()
                WorkspaceReadOnlyTextView(
                    text: displayedScalarValue(scalarValue),
                    usesMonospacedFont: true,
                    accessibilityLabel: AppCopy.current.text(
                        "Redis Key 值",
                        "Redis key value"
                    ),
                    showsBorder: false,
                    presentation: selectedFormat == .json ? .json : .plain
                )
            } else if snapshot.rows.isEmpty {
                ContentUnavailableView(
                    AppCopy.current.text("没有值", "No Value"),
                    systemImage: "key.slash"
                )
            } else {
                RedisKeyCollectionValueView(snapshot: snapshot)
            }

            if snapshot.isTruncated {
                Text(
                    AppCopy.current.text(
                        "仅显示前 500 个元素",
                        "Showing the first 500 elements"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.bar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: scalarValue) {
            await prepareFormats(for: scalarValue)
        }
    }

    private var scalarValue: String? {
        guard keyType == .string,
              snapshot.columns == ["value"],
              snapshot.rows.count == 1,
              snapshot.rows[0].count == 1
        else { return nil }
        return snapshot.rows[0][0]
    }

    private func displayedScalarValue(_ original: String) -> String {
        switch selectedFormat {
        case .text:
            original
        case .json:
            formattedJSON ?? original
        case .hex:
            RedisHexCodec.format(Data(original.utf8))
        }
    }

    private func prepareFormats(for value: String?) async {
        guard let value else {
            formattedJSON = nil
            selectedFormat = .text
            return
        }
        let formatted = await formatter.formattedJSON(from: value)
        guard !Task.isCancelled else { return }
        formattedJSON = formatted
        if formatted == nil {
            selectedFormat = .text
        }
    }
}
