import AppKit
import SwiftUI

struct RedisValueDisplayFormatPicker: NSViewRepresentable {
    @Binding var selectedFormat: RedisValueDisplayFormat
    let allowsText: Bool
    let allowsJSON: Bool
    let allowsHex: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: [""],
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.segmentStyle = .rounded
        control.setAccessibilityLabel(
            AppCopy.current.text("显示格式", "Display Format")
        )
        update(control)
        return control
    }

    func updateNSView(
        _ control: NSSegmentedControl,
        context: Context
    ) {
        context.coordinator.parent = self
        update(control)
    }

    private func update(_ control: NSSegmentedControl) {
        let formats = availableFormats
        control.segmentCount = formats.count
        for (index, format) in formats.enumerated() {
            control.setLabel(format.title, forSegment: index)
        }
        control.selectedSegment = formats.firstIndex(of: selectedFormat) ?? -1
    }

    private var availableFormats: [RedisValueDisplayFormat] {
        RedisValueDisplayFormat.allCases.filter { format in
            switch format {
            case .text: allowsText
            case .json: allowsJSON
            case .hex: allowsHex
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: RedisValueDisplayFormatPicker

        init(parent: RedisValueDisplayFormatPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let formats = parent.availableFormats
            guard formats.indices.contains(sender.selectedSegment)
            else {
                sender.selectedSegment = formats.firstIndex(
                    of: parent.selectedFormat
                ) ?? -1
                return
            }
            parent.selectedFormat = formats[sender.selectedSegment]
        }
    }
}
