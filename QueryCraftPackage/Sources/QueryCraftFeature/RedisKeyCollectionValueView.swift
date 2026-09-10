import SwiftUI

struct RedisKeyCollectionValueView: View {
    let snapshot: RedisKeyValueSnapshot

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Grid(
                    alignment: .leading,
                    horizontalSpacing: 20,
                    verticalSpacing: 0
                ) {
                    GridRow {
                        ForEach(
                            Array(snapshot.columns.enumerated()),
                            id: \.offset
                        ) { _, column in
                            Text(column)
                                .font(.caption)
                                .bold()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 160, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                    }
                    Divider()
                    ForEach(Array(snapshot.rows.enumerated()), id: \.offset) {
                        _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) {
                                _, value in
                                Text(value)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(minWidth: 160, alignment: .leading)
                                    .padding(.vertical, 7)
                            }
                        }
                        Divider()
                    }
                }
                .padding(.horizontal, 12)
                .frame(
                    minWidth: geometry.size.width,
                    minHeight: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
    }
}
