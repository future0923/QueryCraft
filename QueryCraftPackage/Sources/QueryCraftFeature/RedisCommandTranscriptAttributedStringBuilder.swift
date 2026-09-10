import AppKit

@MainActor
enum RedisCommandTranscriptAttributedStringBuilder {
    static func build(
        entries: [RedisCommandTranscriptEntry]
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        append(
            AppCopy.current.text(
                "欢迎使用 Redis 命令控制台\n\n",
                "Welcome to the Redis command console\n\n"
            ),
            color: .secondaryLabelColor,
            to: output
        )

        for entry in entries {
            append(
                "db\(entry.databaseIndex)> ",
                color: .systemOrange,
                weight: .bold,
                to: output
            )
            append("\(entry.command)\n", color: .textColor, to: output)
            appendOutcome(entry.outcome, to: output)
        }
        return output
    }

    private static func appendOutcome(
        _ outcome: RedisCommandTranscriptEntry.Outcome,
        to output: NSMutableAttributedString
    ) {
        switch outcome {
        case .executing:
            append(
                AppCopy.current.text("正在执行…\n\n", "Executing...\n\n"),
                color: .secondaryLabelColor,
                to: output
            )
        case let .success(reply, elapsedSeconds):
            let color: NSColor
            if case .error = reply {
                color = .systemRed
            } else {
                color = .textColor
            }
            append("\(reply.formattedText)\n", color: color, to: output)
            let milliseconds = elapsedSeconds * 1_000
            append(
                "\(milliseconds.formatted(.number.precision(.fractionLength(0...3)))) ms\n\n",
                color: .secondaryLabelColor,
                to: output
            )
        case let .failure(message):
            append("(error) \(message)\n\n", color: .systemRed, to: output)
        case .cancelled:
            append(
                AppCopy.current.text("已取消\n\n", "Cancelled\n\n"),
                color: .secondaryLabelColor,
                to: output
            )
        }
    }

    private static func append(
        _ string: String,
        color: NSColor,
        weight: NSFont.Weight = .regular,
        to output: NSMutableAttributedString
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        output.append(
            NSAttributedString(
                string: string,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: NSFont.systemFontSize,
                        weight: weight
                    ),
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle,
                ]
            )
        )
    }
}
