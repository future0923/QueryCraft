import AppKit
import SwiftUI

struct WorkspaceMainSplitView: NSViewControllerRepresentable {
    let showsSidebar: Bool
    let showsInspector: Bool
    let layoutIdentifier: String
    let onSidebarVisibilityChange: (@MainActor (Bool) -> Void)?
    let onInspectorVisibilityChange: @MainActor (Bool) -> Void
    let sidebarMinimumWidth: CGFloat
    let sidebarMaximumWidth: CGFloat
    let detailMinimumWidth: CGFloat
    let inspectorMinimumWidth: CGFloat
    private let sidebar: AnyView
    private let detail: AnyView
    private let inspector: AnyView

    init<Sidebar: View, Detail: View, Inspector: View>(
        showsSidebar: Bool,
        showsInspector: Bool,
        layoutIdentifier: String = "QueryCraftWorkspaceMainSplit",
        onSidebarVisibilityChange: (@MainActor (Bool) -> Void)? = nil,
        onInspectorVisibilityChange: @escaping @MainActor (Bool) -> Void = { _ in },
        sidebarMinimumWidth: CGFloat,
        sidebarMaximumWidth: CGFloat,
        detailMinimumWidth: CGFloat,
        inspectorMinimumWidth: CGFloat,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder inspector: () -> Inspector
    ) {
        self.showsSidebar = showsSidebar
        self.showsInspector = showsInspector
        self.layoutIdentifier = layoutIdentifier
        self.onSidebarVisibilityChange = onSidebarVisibilityChange
        self.onInspectorVisibilityChange = onInspectorVisibilityChange
        self.sidebarMinimumWidth = sidebarMinimumWidth
        self.sidebarMaximumWidth = sidebarMaximumWidth
        self.detailMinimumWidth = detailMinimumWidth
        self.inspectorMinimumWidth = inspectorMinimumWidth
        self.sidebar = AnyView(sidebar())
        self.detail = AnyView(detail())
        self.inspector = AnyView(inspector())
    }

    func makeNSViewController(
        context: Context
    ) -> WorkspaceMainSplitViewController {
        WorkspaceMainSplitViewController(
            sidebar: sidebar,
            detail: detail,
            inspector: inspector,
            showsSidebar: showsSidebar,
            showsInspector: showsInspector,
            layoutIdentifier: layoutIdentifier,
            onSidebarVisibilityChange: onSidebarVisibilityChange,
            onInspectorVisibilityChange: onInspectorVisibilityChange,
            sidebarMinimumWidth: sidebarMinimumWidth,
            sidebarMaximumWidth: sidebarMaximumWidth,
            detailMinimumWidth: detailMinimumWidth,
            inspectorMinimumWidth: inspectorMinimumWidth
        )
    }

    func updateNSViewController(
        _ controller: WorkspaceMainSplitViewController,
        context: Context
    ) {
        controller.update(
            sidebar: sidebar,
            detail: detail,
            inspector: inspector,
            showsSidebar: showsSidebar,
            showsInspector: showsInspector,
            sidebarMinimumWidth: sidebarMinimumWidth,
            sidebarMaximumWidth: sidebarMaximumWidth,
            detailMinimumWidth: detailMinimumWidth,
            inspectorMinimumWidth: inspectorMinimumWidth
        )
        controller.onInspectorVisibilityChange = onInspectorVisibilityChange
        controller.onSidebarVisibilityChange = onSidebarVisibilityChange
    }

    static func dismantleNSViewController(_ controller: WorkspaceMainSplitViewController, coordinator: ()) {
        controller.invalidate()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: WorkspaceMainSplitViewController,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

@MainActor
final class WorkspaceMainSplitViewController: NSSplitViewController {
    private let layoutIdentifier: String
    private let inspectorWidthKey: String
    private let sidebarWidthKey: String
    private var shouldRestoreSidebarWidth = true
    var onSidebarVisibilityChange: (@MainActor (Bool) -> Void)?
    private var requestedSidebarVisibility: Bool?
    private var isUpdatingSidebarVisibility = false
    private var pendingVisibilityUpdate: Task<Void, Never>?

    private let sidebarHostingController: NSHostingController<AnyView>
    private let detailHostingController: NSHostingController<AnyView>
    private let inspectorHostingController: NSHostingController<AnyView>
    private let initialShowsSidebar: Bool
    private let initialShowsInspector: Bool
    var onInspectorVisibilityChange: @MainActor (Bool) -> Void
    private var requestedInspectorVisibility: Bool?
    private var isUpdatingInspectorVisibility = false
    private var shouldRestoreInspectorWidth = false
    private var sidebarMinimumWidth: CGFloat
    private var sidebarMaximumWidth: CGFloat
    private var detailMinimumWidth: CGFloat
    private var inspectorMinimumWidth: CGFloat
    private var sidebarSplitItem: NSSplitViewItem?
    private var detailSplitItem: NSSplitViewItem?
    private var inspectorSplitItem: NSSplitViewItem?

    init(
        sidebar: AnyView,
        detail: AnyView,
        inspector: AnyView,
        showsSidebar: Bool,
        showsInspector: Bool,
        layoutIdentifier: String = "QueryCraftWorkspaceMainSplit",
        onSidebarVisibilityChange: (@MainActor (Bool) -> Void)? = nil,
        onInspectorVisibilityChange: @escaping @MainActor (Bool) -> Void = { _ in },
        sidebarMinimumWidth: CGFloat,
        sidebarMaximumWidth: CGFloat,
        detailMinimumWidth: CGFloat,
        inspectorMinimumWidth: CGFloat
    ) {
        self.layoutIdentifier = layoutIdentifier
        sidebarWidthKey = layoutIdentifier + ".sidebarLastWidth"
        inspectorWidthKey = layoutIdentifier == "QueryCraftWorkspaceMainSplit"
            ? "QueryCraftWorkspaceInspectorLastWidth" : layoutIdentifier + ".inspectorLastWidth"
        self.onSidebarVisibilityChange = onSidebarVisibilityChange
        sidebarHostingController = NSHostingController(rootView: sidebar)
        detailHostingController = NSHostingController(rootView: detail)
        inspectorHostingController = NSHostingController(rootView: inspector)
        initialShowsSidebar = showsSidebar
        initialShowsInspector = showsInspector
        self.onInspectorVisibilityChange = onInspectorVisibilityChange
        self.sidebarMinimumWidth = sidebarMinimumWidth
        self.sidebarMaximumWidth = sidebarMaximumWidth
        self.detailMinimumWidth = detailMinimumWidth
        self.inspectorMinimumWidth = inspectorMinimumWidth
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WorkspaceMainSplitViewController does not support NSCoder")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        sidebarHostingController.sizingOptions = []
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarHostingController
        )
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = sidebarMinimumWidth
        sidebarItem.maximumThickness = sidebarMaximumWidth
        sidebarItem.isCollapsed = !initialShowsSidebar
        addSplitViewItem(sidebarItem)
        sidebarSplitItem = sidebarItem

        detailHostingController.sizingOptions = []
        let detailItem = NSSplitViewItem(
            viewController: detailHostingController
        )
        detailItem.minimumThickness = detailMinimumWidth
        detailItem.holdingPriority = .defaultLow
        addSplitViewItem(detailItem)
        detailSplitItem = detailItem

        inspectorHostingController.sizingOptions = []
        let inspectorItem = NSSplitViewItem(
            inspectorWithViewController: inspectorHostingController
        )
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = inspectorMinimumWidth
        inspectorItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
        inspectorItem.isCollapsed = !initialShowsInspector
        addSplitViewItem(inspectorItem)
        inspectorSplitItem = inspectorItem

        // A bidirectional consumer owns its visibility explicitly. Native frame
        // autosave also restores collapsed flags and would compete with that state.
        splitView.autosaveName = onSidebarVisibilityChange == nil ? NSSplitView.AutosaveName(layoutIdentifier) : nil
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        enforceThicknessConstraintsIfNeeded()
        restoreInspectorWidthIfNeeded()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard pendingVisibilityUpdate == nil else { return }
        if !isUpdatingSidebarVisibility, let onSidebarVisibilityChange,
           let requestedSidebarVisibility, let sidebarSplitItem {
            let isVisible = !sidebarSplitItem.isCollapsed
            let width = sidebarSplitItem.viewController.view.frame.width
            if isVisible, !shouldRestoreSidebarWidth, width >= sidebarMinimumWidth {
                UserDefaults.standard.set(Double(width), forKey: sidebarWidthKey)
            }
            if isVisible != requestedSidebarVisibility {
                self.requestedSidebarVisibility = isVisible
                onSidebarVisibilityChange(isVisible)
            }
        }
        guard !isUpdatingInspectorVisibility,
              let requestedInspectorVisibility,
              let inspectorSplitItem
        else { return }
        let isVisible = !inspectorSplitItem.isCollapsed
        if isVisible != requestedInspectorVisibility {
            self.requestedInspectorVisibility = isVisible
            onInspectorVisibilityChange(isVisible)
        }
        if isVisible {
            let width = inspectorSplitItem.viewController.view.frame.width
            if width >= inspectorMinimumWidth {
                UserDefaults.standard.set(
                    Double(width),
                    forKey: inspectorWidthKey
                )
            }
        }
    }

    func update(
        sidebar: AnyView,
        detail: AnyView,
        inspector: AnyView,
        showsSidebar: Bool,
        showsInspector: Bool,
        sidebarMinimumWidth: CGFloat,
        sidebarMaximumWidth: CGFloat,
        detailMinimumWidth: CGFloat,
        inspectorMinimumWidth: CGFloat
    ) {
        let previousSidebarWidth = visibleWidth(of: sidebarSplitItem)

        sidebarHostingController.rootView = sidebar
        detailHostingController.rootView = detail
        inspectorHostingController.rootView = inspector

        self.sidebarMinimumWidth = sidebarMinimumWidth
        self.sidebarMaximumWidth = sidebarMaximumWidth
        self.detailMinimumWidth = detailMinimumWidth
        self.inspectorMinimumWidth = inspectorMinimumWidth
        updateThicknessConstraints()

        if onSidebarVisibilityChange != nil {
            // SSH opts into bidirectional visibility. Collapse on the next actor
            // turn, after hosted SwiftUI roots finish updating, to avoid reentering
            // their layout graph. Superseded requests never reach AppKit.
            let restoreWidth = requestedInspectorVisibility != showsInspector && showsInspector
            if requestedSidebarVisibility != showsSidebar && showsSidebar { shouldRestoreSidebarWidth = true }
            requestedSidebarVisibility = showsSidebar
            requestedInspectorVisibility = showsInspector
            shouldRestoreInspectorWidth = shouldRestoreInspectorWidth || restoreWidth
            pendingVisibilityUpdate?.cancel()
            pendingVisibilityUpdate = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.isUpdatingSidebarVisibility = true
                self.isUpdatingInspectorVisibility = true
                if self.sidebarSplitItem?.isCollapsed == showsSidebar { self.sidebarSplitItem?.isCollapsed = !showsSidebar }
                if self.inspectorSplitItem?.isCollapsed == showsInspector { self.inspectorSplitItem?.isCollapsed = !showsInspector }
                let savedSidebarWidth = CGFloat(UserDefaults.standard.double(forKey: self.sidebarWidthKey))
                let sidebarWidth = self.shouldRestoreSidebarWidth && savedSidebarWidth >= self.sidebarMinimumWidth
                    ? savedSidebarWidth : previousSidebarWidth
                self.enforceThicknessConstraintsIfNeeded(preferredSidebarWidth: sidebarWidth)
                self.restoreInspectorWidthIfNeeded()
                if showsSidebar { self.shouldRestoreSidebarWidth = false }
                self.isUpdatingSidebarVisibility = false
                self.isUpdatingInspectorVisibility = false
                self.pendingVisibilityUpdate = nil
            }
            return
        }
        if sidebarSplitItem?.isCollapsed == showsSidebar {
            sidebarSplitItem?.isCollapsed = !showsSidebar
        }
        if requestedInspectorVisibility != showsInspector {
            requestedInspectorVisibility = showsInspector
            isUpdatingInspectorVisibility = true
            if inspectorSplitItem?.isCollapsed == showsInspector {
                inspectorSplitItem?.isCollapsed = !showsInspector
            }
            shouldRestoreInspectorWidth = showsInspector
            enforceThicknessConstraintsIfNeeded(
                preferredSidebarWidth: previousSidebarWidth
            )
            restoreInspectorWidthIfNeeded()
            isUpdatingInspectorVisibility = false
            return
        }

        enforceThicknessConstraintsIfNeeded(
            preferredSidebarWidth: previousSidebarWidth
        )
    }

    func invalidate() {
        pendingVisibilityUpdate?.cancel(); pendingVisibilityUpdate = nil
        onSidebarVisibilityChange = nil
        onInspectorVisibilityChange = { _ in }
    }

    private func restoreInspectorWidthIfNeeded() {
        guard shouldRestoreInspectorWidth,
              let inspectorSplitItem,
              !inspectorSplitItem.isCollapsed,
              splitView.bounds.width > 0
        else { return }
        shouldRestoreInspectorWidth = false
        let savedWidth = CGFloat(
            UserDefaults.standard.double(forKey: inspectorWidthKey)
        )
        guard savedWidth >= inspectorMinimumWidth else { return }
        let availableWidth = splitView.bounds.width
            - sidebarMinimumWidth - detailMinimumWidth
            - 2 * splitView.dividerThickness
        guard availableWidth >= inspectorMinimumWidth else { return }
        let width = min(savedWidth, availableWidth)
        let previousUpdatingState = isUpdatingInspectorVisibility
        isUpdatingInspectorVisibility = true
        splitView.setPosition(
            splitView.bounds.width - width - splitView.dividerThickness,
            ofDividerAt: 1
        )
        isUpdatingInspectorVisibility = previousUpdatingState
    }

    private func updateThicknessConstraints() {
        sidebarSplitItem?.minimumThickness = sidebarMinimumWidth
        sidebarSplitItem?.maximumThickness = sidebarMaximumWidth
        detailSplitItem?.minimumThickness = detailMinimumWidth
        inspectorSplitItem?.minimumThickness = inspectorMinimumWidth
    }

    private func enforceThicknessConstraintsIfNeeded(
        preferredSidebarWidth: CGFloat? = nil
    ) {
        guard splitView.bounds.width > 0 else { return }

        updateThicknessConstraints()

        if let sidebarSplitItem, !sidebarSplitItem.isCollapsed {
            let currentWidth = sidebarSplitItem.viewController.view.frame.width
            let desiredWidth = min(
                max(
                    preferredSidebarWidth ?? currentWidth,
                    sidebarMinimumWidth
                ),
                sidebarMaximumWidth
            )
            if abs(currentWidth - desiredWidth) >= 0.5 {
                let dividerPosition = sidebarSplitItem
                    .viewController.view.frame.maxX
                    + desiredWidth
                    - currentWidth
                splitView.setPosition(
                    dividerPosition,
                    ofDividerAt: 0
                )
            }
        }

        if let inspectorSplitItem, !inspectorSplitItem.isCollapsed {
            let currentWidth = inspectorSplitItem.viewController.view.frame.width
            if currentWidth < inspectorMinimumWidth {
                let dividerPosition = splitView.bounds.width
                    - inspectorMinimumWidth
                    - splitView.dividerThickness
                splitView.setPosition(
                    dividerPosition,
                    ofDividerAt: 1
                )
            }
        }
    }

    private func visibleWidth(of item: NSSplitViewItem?) -> CGFloat? {
        guard let item, !item.isCollapsed else { return nil }
        return item.viewController.view.frame.width
    }
}
