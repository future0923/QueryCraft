import AppKit

@MainActor
final class WorkspaceContentTabHostContainerController: NSViewController {
    private var installedHostControllers: [
        ObjectIdentifier: WorkspaceRetainedContentHostController
    ] = [:]
    private(set) var contentHostController:
        WorkspaceRetainedContentHostController?

    override func loadView() {
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        view = containerView
    }

    func show(
        _ incoming: WorkspaceRetainedContentHostController,
        retaining retainedControllers: [WorkspaceRetainedContentHostController]
    ) {
        loadViewIfNeeded()

        let outgoing = contentHostController
        let firstResponderWasInsideOutgoing = outgoing.flatMap { controller in
            guard let responder = view.window?.firstResponder as? NSView else {
                return false
            }
            return responder === controller.view
                || responder.isDescendant(of: controller.view)
        } ?? false

        let retainedIDs = Set(retainedControllers.map(ObjectIdentifier.init))
        let obsoleteIDs = installedHostControllers.compactMap { id, controller in
            !retainedIDs.contains(id) && controller !== incoming ? id : nil
        }
        for id in obsoleteIDs {
            guard let controller = installedHostControllers.removeValue(
                forKey: id
            ) else { continue }
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }

        guard contentHostController !== incoming else { return }
        outgoing?.view.removeFromSuperview()

        let incomingID = ObjectIdentifier(incoming)
        if installedHostControllers[incomingID] == nil {
            addChild(incoming)
            let contentView = incoming.view
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentView.autoresizingMask = [.width, .height]
            contentView.frame = view.bounds
            installedHostControllers[incomingID] = incoming
        }
        incoming.view.frame = view.bounds
        incoming.view.setAccessibilityHidden(false)
        view.addSubview(incoming.view, positioned: .above, relativeTo: nil)
        contentHostController = incoming

        if firstResponderWasInsideOutgoing {
            view.window?.makeFirstResponder(incoming.view)
        }
    }
}
