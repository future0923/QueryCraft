import AppKit
import SwiftUI

/// Each well owns a fixed role/appearance binding. Removing it detaches the shared panel.
struct EditorColorWell: NSViewRepresentable {
    let color: NSColor
    let label: String
    let beginChange: () -> Void
    let change: (NSColor) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Well {
        let well = Well()
        well.colorWellStyle = .minimal
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        return well
    }
    func updateNSView(_ well: Well, context: Context) {
        context.coordinator.change = change
        well.beginChange = beginChange
        if well.color != color { well.color = color }
        well.setAccessibilityLabel(label)
    }
    static func dismantleNSView(_ well: Well, coordinator: Coordinator) {
        let wasActive = well.isActive
        well.deactivate()
        if wasActive { NSColorPanel.shared.orderOut(nil) }
        well.target = nil
        coordinator.change = nil
    }
    final class Well: NSColorWell {
        var beginChange: (() -> Void)?
        override func activate(_ exclusive: Bool) {
            beginChange?()
            NSColorPanel.shared.showsAlpha = false
            super.activate(exclusive)
        }
    }
    @MainActor final class Coordinator: NSObject {
        var change: ((NSColor) -> Void)?
        @objc func changed(_ sender: NSColorWell) { change?(sender.color) }
    }
}

struct EditorHexField: View {
    let value: String
    let label: String
    let commit: (String) -> Void
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: $draft)
                .labelsHidden()
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { _, focus in if !focus { apply() } }
                .onChange(of: draft) { _, _ in invalid = false }
                .onChange(of: value) { _, newValue in draft = newValue; invalid = false }
                .onAppear { draft = value }
                .accessibilityLabel(label + " HEX")
            if invalid {
                Text(AppCopy.current.text("请输入 6 位 HEX", "Use 6-digit HEX"))
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .frame(width: 108)
    }
    private func apply() {
        guard let hex = EditorHexColor.normalized(draft) else { invalid = true; return }
        draft = hex
        invalid = false
        if hex != value { commit(hex) }
    }
}
