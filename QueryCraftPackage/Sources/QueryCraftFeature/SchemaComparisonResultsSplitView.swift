import AppKit
import SwiftUI

/// A native divider keeps the definition readable in tall windows and remembers
/// the user's chosen proportion independently of the window dimensions.
struct SchemaComparisonResultsSplitView<Objects: View, Detail: View>: NSViewControllerRepresentable {
    @ViewBuilder var objects: () -> Objects
    @ViewBuilder var detail: () -> Detail

    func makeNSViewController(context: Context) -> SchemaComparisonResultsSplitViewController {
        SchemaComparisonResultsSplitViewController(objects: AnyView(objects()), detail: AnyView(detail()))
    }

    func updateNSViewController(_ controller: SchemaComparisonResultsSplitViewController, context: Context) {
        controller.objects.rootView = AnyView(objects())
        controller.detail.rootView = AnyView(detail())
    }
}

@MainActor final class SchemaComparisonResultsSplitViewController: NSSplitViewController {
    let objects: NSHostingController<AnyView>
    let detail: NSHostingController<AnyView>
    private let defaults: UserDefaults?
    private let storageKey = "schemaComparison.resultsObjectFraction"
    private var fraction: CGFloat
    private var layoutHeight: CGFloat = 0
    private var applyingPosition = false

    init(objects: AnyView, detail: AnyView, defaults: UserDefaults? = .standard) {
        self.objects = NSHostingController(rootView: objects)
        self.detail = NSHostingController(rootView: detail)
        self.defaults = defaults
        let saved = defaults?.double(forKey: storageKey) ?? 0
        fraction = saved > 0 ? min(0.8, max(0.2, saved)) : 0.6
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.setAccessibilityIdentifier("schemaComparisonResultsSplit")
        for (controller, minimum) in [(self.objects, 160.0), (self.detail, 180.0)] {
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = minimum
            item.canCollapse = false
            addSplitViewItem(item)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(dividerMoved), name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLayout() {
        super.viewDidLayout()
        let height = splitView.bounds.height
        guard view.window != nil, height > 340, abs(height - layoutHeight) > 0.5 else { return }
        layoutHeight = height
        applyingPosition = true
        defer { applyingPosition = false }
        splitView.setPosition((height - splitView.dividerThickness) * fraction, ofDividerAt: 0)
    }

    @objc private func dividerMoved() {
        guard !applyingPosition, layoutHeight > 340,
              abs(splitView.bounds.height - layoutHeight) < 0.5,
              view.window?.inLiveResize != true else { return }
        let available = splitView.bounds.height - splitView.dividerThickness
        let current = objects.view.frame.height / available
        // Ignore transient constraint/layout notifications until both panes fit.
        guard current >= 0.2, current <= 0.8 else { return }
        fraction = current
        defaults?.set(Double(current), forKey: storageKey)
    }
}
