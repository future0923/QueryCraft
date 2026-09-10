import SwiftUI

struct WorkspaceSQLPreviewView: View {
    let statements: [WorkspaceSQLPreviewStatement]
    let dismiss: @MainActor () -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(statements.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(index + 1))
                            .font(.body.monospaced())
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .frame(
                                width: lineNumberColumnWidth,
                                alignment: .trailing
                            )
                            .accessibilityHidden(true)

                        Divider()

                        Text(attributedSQL(for: statements[index]))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .topLeading
                            )
                    }
                }
            }
            .padding()
            .frame(
                minWidth: 600,
                minHeight: 300,
                alignment: .topLeading
            )
        }
        .scrollContentBackground(.visible)
        .frame(width: 600, height: 300)
        .background {
            WorkspaceSQLPreviewKeyCommandHandler(dismiss: dismiss)
        }
        .accessibilityLabel(AppCopy.current.text("SQL 预览", "SQL Preview"))
    }

    private var lineNumberColumnWidth: CGFloat {
        CGFloat(max(2, String(max(statements.count, 1)).count)) * 9
    }

    private func attributedSQL(
        for statement: WorkspaceSQLPreviewStatement
    ) -> AttributedString {
        var result = AttributedString()
        for token in statement.tokens {
            var fragment = AttributedString(token.text)
            fragment.font = .body.monospaced()
            fragment.foregroundColor = color(for: token.kind)
            result.append(fragment)
        }
        return result
    }

    private func color(
        for kind: WorkspaceSQLPreviewToken.Kind
    ) -> Color {
        switch kind {
        case .keyword:
            .blue
        case .identifier:
            .orange
        case .stringLiteral:
            .red
        case .nullLiteral:
            .purple
        case .numericLiteral:
            .purple
        case .expression:
            .primary
        case .punctuation:
            .primary
        }
    }
}
