import SwiftUI
import UIKit

/// SwiftUI's vertical TextField inserts a newline even with submitLabel(.done).
/// This native editor keeps complete multiline text/IME/undo, and Done resigns
/// only its own responder; no window-global keyboard action or accessory button.
struct MobileDataValueInput: UIViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear; view.textAlignment = .right
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .init(top: 6, left: 0, bottom: 6, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .done; view.autocapitalizationType = .none; view.autocorrectionType = .no
        view.text = text; view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.markedTextRange == nil, view.text != text { view.text = text }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let height = uiView.sizeThatFits(.init(width: width, height: .greatestFiniteMagnitude)).height
        return .init(width: width, height: min(180, max(36, height)))
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileDataValueInput
        init(_ parent: MobileDataValueInput) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil {
                textView.resignFirstResponder(); parent.onSubmit(); return false
            }
            return true
        }
    }
}
