import AppKit
import SwiftUI

/// Custom AppKit editors do not participate in SwiftUI's automatic focus values.
/// Publish their commands only while their actual native responder owns focus.
struct WorkspaceNativeFocusObserver: NSViewRepresentable {
    let matches: @MainActor (NSResponder?) -> Bool
    var requiresContainedResponder = false
    let didChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> FocusView {
        FocusView(matches: matches, requiresContainedResponder: requiresContainedResponder, didChange: didChange)
    }

    func updateNSView(_ view: FocusView, context: Context) {
        view.matches = matches
        view.requiresContainedResponder = requiresContainedResponder
        view.didChange = didChange
        view.scheduleUpdate()
    }

    static func dismantleNSView(_ view: FocusView, coordinator: ()) {
        view.stop()
    }

    final class FocusView: NSView {
        var matches: @MainActor (NSResponder?) -> Bool
        var requiresContainedResponder: Bool
        var didChange: @MainActor (Bool) -> Void
        private var observation: NSKeyValueObservation?
        private var editingObservers: [NSObjectProtocol] = []
        private var reportedFocus: Bool?
        private var isStopped = false

        init(matches: @escaping @MainActor (NSResponder?) -> Bool,
             requiresContainedResponder: Bool = false,
             didChange: @escaping @MainActor (Bool) -> Void) {
            self.matches = matches
            self.requiresContainedResponder = requiresContainedResponder
            self.didChange = didChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            editingObservers.forEach(NotificationCenter.default.removeObserver)
            editingObservers.removeAll()
            observation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.reportFocus() }
            }
            if window != nil {
                // AppKit reuses a window's field editor when moving between
                // controls. Its identity (and firstResponder KVO) may not change.
                // Recheck the owning control after the window processes events.
                editingObservers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate() }
                })
                for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
                    editingObservers.append(NotificationCenter.default.addObserver(forName: name,
                        object: nil, queue: .main) { [weak self] notification in
                        let control = notification.object as? NSView
                        MainActor.assumeIsolated {
                            guard let self, let window = self.window,
                                  control?.window === window else { return }
                            self.scheduleUpdate()
                        }
                    })
                }
            }
            scheduleUpdate()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleUpdate()
        }

        func scheduleUpdate() {
            Task { @MainActor [weak self] in self?.reportFocus() }
        }

        private func reportFocus() {
            let focused = !isStopped && window != nil && matches(window?.firstResponder)
                && (!requiresContainedResponder || containsNativeResponder())
            guard reportedFocus != focused else { return }
            reportedFocus = focused
            didChange(focused)
        }

        private func containsNativeResponder() -> Bool {
            let responder = window?.firstResponder
            let target: NSView?
            if let editor = responder as? NSTextView, editor.isFieldEditor {
                target = editor.delegate as? NSView
            } else {
                target = responder as? NSView
            }
            guard let target, target.window === window,
                  !isHiddenOrHasHiddenAncestor, !target.isHiddenOrHasHiddenAncestor else { return false }
            // AppKit can report a visibleRect extending beyond a control's
            // bounds (notably for field editors and non-layer-backed views).
            let targetRect = target.convert(target.bounds.intersection(target.visibleRect), to: nil)
            let scope = convert(bounds, to: nil)
            guard !targetRect.isEmpty, !scope.isEmpty else { return false }
            return scope.contains(NSPoint(x: targetRect.midX, y: targetRect.midY))
        }

        func stop() {
            isStopped = true
            observation = nil
            editingObservers.forEach(NotificationCenter.default.removeObserver)
            editingObservers.removeAll()
            scheduleUpdate()
        }
    }
}

extension View {
    func workspaceFocusedValue<Value>(
        _ keyPath: WritableKeyPath<FocusedValues, Value?>,
        _ value: Value?,
        matches: @escaping @MainActor (NSResponder?) -> Bool = { _ in true }
    ) -> some View {
        modifier(WorkspaceNativeScopedValue(keyPath: keyPath, value: value, matches: matches))
    }
}

private struct WorkspaceNativeScopedValue<Value>: ViewModifier {
    let keyPath: WritableKeyPath<FocusedValues, Value?>
    let value: Value?
    let matches: @MainActor (NSResponder?) -> Bool
    @State private var matchesResponder = true

    func body(content: Content) -> some View {
        // SwiftUI supplies the view scope; the native observer only adds the
        // responder-type predicate (for example, no row actions while typing).
        content
            .background {
                WorkspaceNativeFocusObserver(matches: matches,
                    didChange: { matchesResponder = $0 })
                    .allowsHitTesting(false)
            }
            .focusedValue(keyPath, matchesResponder ? value : nil)
    }
}
