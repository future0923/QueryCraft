import SwiftUI

struct WorkspaceRedisCommandPreviewView: View {
    let commands: [RedisCommandInvocation]
    let dismiss: @MainActor () -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(commands.indices, id: \.self) { index in
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

                        Text(attributedCommand(commands[index]))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .topLeading
                            )
                    }
                    .padding(.vertical, 3)
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
        .accessibilityLabel(
            AppCopy.current.text("Redis 命令预览", "Redis Command Preview")
        )
    }

    private var lineNumberColumnWidth: CGFloat {
        CGFloat(max(2, String(max(commands.count, 1)).count)) * 9
    }

    private func attributedCommand(
        _ invocation: RedisCommandInvocation
    ) -> AttributedString {
        var result = AttributedString()
        for (index, argument) in invocation.arguments.enumerated() {
            if index > 0 {
                result.append(AttributedString(" "))
            }
            var fragment = AttributedString(
                RedisCommandPreviewFormatter.escaped(argument)
            )
            fragment.font = .body.monospaced()
            fragment.foregroundColor = index == 0 ? .blue : .primary
            result.append(fragment)
        }
        return result
    }
}
