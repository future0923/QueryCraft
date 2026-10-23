import SwiftUI

struct MobileFullscreenGridSelection: Identifiable {
    let id = UUID()
    let data: MobileGridData
    let revision: String
    let widthKey: String
    let viewport: MobileGridViewport
    var timestampScope: String? = nil
    var pageContext: MobileGridPageContext? = nil
    var source: MobileResultSource? = nil
}

/// No NavigationStack: no sidebar, toolbar, tab bar, editor or footer reserves space.
struct MobileFullscreenGrid: View {
    let selection: MobileFullscreenGridSelection
    @Environment(\.dismiss) private var dismiss
    @State private var showsExit = true
    @State private var exitTimerID = UUID()
    @State private var cellPresentation: MobileResultCellPresentation?
    @State private var pendingChanges: MobileTableChanges?
    @State private var restorationID = UUID()

    var body: some View {
        let data = selection.source?.data ?? selection.data
        let changes = selection.source?.snapshot.editing
        ZStack(alignment: .topTrailing) {
            MobileDataGrid(data: data, revision: selection.source?.revision ?? selection.revision, widthKey: selection.widthKey,
                           viewport: selection.viewport, restorationID: restorationID,
                           tracksViewport: cellPresentation == nil && pendingChanges == nil, viewportOwner: selection.id,
                           cellAccessibilityHint: "轻点查看或编辑；长按查看待提交改动", timestampScope: selection.timestampScope,
                           pageContext: selection.pageContext, pendingChangeCount: changes?.changeCount ?? 0,
                           onShowPendingChanges: changes.map { captured in { pendingChanges = captured } }) { row, column in
                revealExit()
                if let source = selection.source { cellPresentation = source.cell(row: row, column: column) }
                else if data.rows.indices.contains(row), data.columns.indices.contains(column) {
                    cellPresentation = .init(content: .inspect(.init(row: row, column: column, name: data.columns[column], value: data.cell(row: row, column: column)), nil))
                }
            }
                .simultaneousGesture(TapGesture().onEnded { revealExit() })
                Button("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left") { dismiss() }
                    .labelStyle(.iconOnly).font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .background(.regularMaterial, in: .circle).padding(12)
                    .opacity(showsExit ? 1 : 0).allowsHitTesting(showsExit).accessibilityHidden(!showsExit)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityIdentifier("exitFullscreenGrid")
        }
            // Only the background bleeds to the edge. Readable cells and the pinned
            // header stay inside the hardware safe area in either orientation.
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .ignoresSafeArea(.keyboard)
            .background(MobileFullscreenInputGuard(permitsPresentedInput: true))
            .sheet(item: $cellPresentation, onDismiss: resumeGrid) { MobileResultCellSheet(presentation: $0) }
            .sheet(item: $pendingChanges, onDismiss: resumeGrid) { MobilePendingChangesView(changes: $0) }
            .onChange(of: selection.source?.isCurrent) { _, current in if current == false { dismiss() } }
            .task {
                #if DEBUG
                if let source = selection.source {
                    let scene = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SURFACE"]
                    if scene == "full-cell" { cellPresentation = source.cell(row: 0, column: 1) }
                    if scene == "full-pending", let captured = try? source.edit(row: 0, column: 1) {
                        try? captured.changes.stage(captured.request, text: "全屏暂存示例", mode: .value)
                        pendingChanges = captured.changes
                    }
                }
                #endif
            }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .accessibilityAction(.escape) { dismiss() }
            .task(id: exitTimerID) {
                guard !UIAccessibility.isVoiceOverRunning else { return }
                do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation(); showsExit = false }
                catch { }
            }
            .accessibilityIdentifier("fullscreenGrid")
    }

    private func revealExit() { showsExit = true; exitTimerID = UUID() }
    private func resumeGrid() { restorationID = UUID(); revealExit() }
}

/// Clear retained search/editor responders in this presentation's window, including
/// UIKit focus restoration during rotation. Never resign input in another scene.
struct MobileFullscreenInputGuard: UIViewRepresentable {
    var permitsPresentedInput = false
    func makeUIView(context: Context) -> MobileFullscreenInputGuardView {
        let view = MobileFullscreenInputGuardView()
        view.permitsPresentedInput = permitsPresentedInput
        return view
    }
    func updateUIView(_ view: MobileFullscreenInputGuardView, context: Context) { view.permitsPresentedInput = permitsPresentedInput }
    static func dismantleUIView(_ view: MobileFullscreenInputGuardView, coordinator: ()) { view.stopObserving() }
}

@MainActor final class MobileFullscreenInputGuardView: UIView {
    var permitsPresentedInput = false

    private var hasAllowedPresentedInput: Bool {
        guard permitsPresentedInput, let window,
              let responder = firstResponder(in: window) else { return false }
        var current: UIResponder? = self
        while let item = current {
            if let controller = item as? UIViewController {
                var presented = controller.presentedViewController
                while let overlay = presented {
                    if overlay.isViewLoaded, responder.isDescendant(of: overlay.view) { return true }
                    presented = overlay.presentedViewController
                }
            }
            current = item.next
        }
        return false
    }
    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        return view.subviews.lazy.compactMap { self.firstResponder(in: $0) }.first
    }
    private var lastSize = CGSize.zero
    private var observing = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        observing = true
        NotificationCenter.default.addObserver(self, selector: #selector(dismissRetainedInput),
                                              name: UIResponder.keyboardWillShowNotification, object: nil)
        dismissRetainedInput()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        dismissRetainedInput()
    }

    @objc private func dismissRetainedInput() {
        guard observing, !hasAllowedPresentedInput, let window else { return }
        window.endEditing(true)
        // The keyboard/rotation transition may restore a responder later this turn.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.observing, !self.hasAllowedPresentedInput, let window, self.window === window else { return }
            window.endEditing(true)
        }
    }

    func stopObserving() {
        observing = false
        NotificationCenter.default.removeObserver(self)
    }
}
