import AppKit
import SwiftUI

struct WorkspaceMainSplitView: NSViewControllerRepresentable {
    let showsSidebar: Bool
    let showsInspector: Bool
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
    private static let autosaveName =
        NSSplitView.AutosaveName("QueryCraftWorkspaceMainSplit")

    private let sidebarHostingController: NSHostingController<AnyView>
    private let detailHostingController: NSHostingController<AnyView>
    private let inspectorHostingController: NSHostingController<AnyView>
    private let initialShowsSidebar: Bool
    private let initialShowsInspector: Bool
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
        sidebarMinimumWidth: CGFloat,
        sidebarMaximumWidth: CGFloat,
        detailMinimumWidth: CGFloat,
        inspectorMinimumWidth: CGFloat
    ) {
        sidebarHostingController = NSHostingController(rootView: sidebar)
        detailHostingController = NSHostingController(rootView: detail)
        inspectorHostingController = NSHostingController(rootView: inspector)
        initialShowsSidebar = showsSidebar
        initialShowsInspector = showsInspector
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

        splitView.autosaveName = Self.autosaveName
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        enforceThicknessConstraintsIfNeeded()
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

        if sidebarSplitItem?.isCollapsed == showsSidebar {
            sidebarSplitItem?.isCollapsed = !showsSidebar
        }
        if inspectorSplitItem?.isCollapsed == showsInspector {
            inspectorSplitItem?.isCollapsed = !showsInspector
        }

        enforceThicknessConstraintsIfNeeded(
            preferredSidebarWidth: previousSidebarWidth
        )
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
