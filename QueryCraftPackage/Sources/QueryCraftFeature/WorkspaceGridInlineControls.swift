import AppKit

/// Shared direct-drawn controls for SQL Structure and document Mapping rows.
/// A row owns one native cell; passive controls never add subviews to the grid.
@MainActor
final class WorkspaceGridInlineControls {
    static let disclosureWidth: CGFloat = 16

    private lazy var checkboxCell: NSButtonCell = {
        let cell = NSButtonCell()
        cell.setButtonType(.switch)
        cell.title = ""
        cell.controlSize = .small
        cell.isBordered = false
        cell.allowsMixedState = true
        return cell
    }()
    private lazy var disclosureImage: NSImage? = {
        NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(hierarchicalColor: .secondaryLabelColor))
            )
    }()
    private lazy var unavailableImage = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .tertiaryLabelColor)))

    private func checkboxFrame(in rect: NSRect) -> NSRect {
        let side: CGFloat = 18
        return NSRect(x: rect.minX + 5, y: floor(rect.midY - side / 2), width: side, height: side)
    }

    func drawCheckbox(_ state: NSControl.StateValue, in rect: NSRect, view: NSView,
                      isSelected: Bool, isEnabled: Bool) {
        checkboxCell.state = state
        checkboxCell.isEnabled = isEnabled
        checkboxCell.backgroundStyle = isSelected ? .emphasized : .normal
        checkboxCell.draw(withFrame: checkboxFrame(in: rect), in: view)
    }

    func drawUnavailable(in rect: NSRect, isSelected: Bool) {
        guard let unavailableImage else { return }
        let image = isSelected
            ? unavailableImage.withSymbolConfiguration(NSImage.SymbolConfiguration(
                hierarchicalColor: .alternateSelectedControlTextColor)) ?? unavailableImage
            : unavailableImage
        let frame = checkboxFrame(in: rect)
        let size = image.size
        image.draw(in: NSRect(x: floor(frame.midX - size.width / 2),
                             y: floor(frame.midY - size.height / 2), width: size.width, height: size.height))
    }

    func drawDisclosure(in rect: NSRect, isSelected: Bool) {
        guard let disclosureImage else { return }
        let image = isSelected
            ? disclosureImage.withSymbolConfiguration(NSImage.SymbolConfiguration(
                hierarchicalColor: .alternateSelectedControlTextColor)) ?? disclosureImage
            : disclosureImage
        let size = NSSize(width: 12, height: 14)
        image.draw(in: NSRect(x: rect.maxX - size.width - 4, y: floor(rect.midY - size.height / 2),
                             width: size.width, height: size.height))
    }
}

enum WorkspaceGridInlineControl {
    // Status presentation is separate from the grid's edit permissions.
    case booleanIndicator(NSControl.StateValue)
    case options
    case unavailable
}
