import AppKit
import SwiftUI

struct WorkspaceQueryResultInspectorFieldRow: View {
    let field: WorkspaceQueryResultInspectorField

    @State private var formattedJSON: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(field.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .help(field.name)

                Spacer(minLength: 8)

                if !field.type.isEmpty {
                    Text(typeBadgeLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help(field.type)
                }
            }

            valueContent
        }
        .contextMenu {
            Button(AppCopy.current.text("复制值", "Copy Value"), action: copyValue)
        }
        .task(id: field.id) {
            formattedJSON = nil
            guard field.shouldFormatJSON, let text = field.textValue else {
                return
            }
            do {
                let formatted =
                    try await WorkspaceQueryResultInspectorFormatter
                    .shared.formattedJSON(text)
                try Task.checkCancellation()
                formattedJSON = formatted
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    @ViewBuilder
    private var valueContent: some View {
        switch field.value {
        case .null:
            placeholder(AppCopy.current.text("NULL", "NULL"))

        case .text(let text) where text.isEmpty:
            placeholder(AppCopy.current.text("空字符串", "Empty String"))

        case .text:
            let displayedText = formattedJSON ?? field.displayedText ?? ""
            if field.isLongText || formattedJSON != nil {
                WorkspaceReadOnlyTextView(
                    text: displayedText,
                    usesMonospacedFont: formattedJSON != nil,
                    accessibilityLabel: field.name,
                    presentation: field.shouldFormatJSON ? .json : .automaticJSON
                )
                .frame(minHeight: 72, idealHeight: 120, maxHeight: 180)
            } else {
                Text(displayedText)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor))
                    }
            }

        case .binary:
            binaryContent
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor))
            }
    }

    @ViewBuilder
    private var binaryContent: some View {
        if let binary = field.binaryDisplay {
            VStack(alignment: .leading, spacing: 4) {
                Text(binaryStatus(binary))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if binary.hex.isEmpty {
                    placeholder(
                        AppCopy.current.text(
                            "没有可用的二进制预览",
                            "No binary preview available"
                        )
                    )
                } else {
                    WorkspaceReadOnlyTextView(
                        text: binary.hex,
                        usesMonospacedFont: true,
                        accessibilityLabel: field.name
                    )
                    .frame(minHeight: 72, idealHeight: 96, maxHeight: 140)
                }
            }
        }
    }

    private func binaryStatus(
        _ binary: (byteCount: Int, previewCount: Int, hex: String)
    ) -> String {
        if binary.previewCount < binary.byteCount {
            return AppCopy.current.text(
                "共 \(binary.byteCount) 字节，显示前 \(binary.previewCount) 字节",
                "\(binary.byteCount) bytes, showing the first \(binary.previewCount)"
            )
        }
        return AppCopy.current.text(
            "\(binary.byteCount) 字节",
            "\(binary.byteCount) bytes"
        )
    }

    private var typeBadgeLabel: String {
        field.type
            .replacing("MYSQL_TYPE_", with: "")
            .lowercased()
    }

    private func copyValue() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(field.copyText, forType: .string)
    }
}
