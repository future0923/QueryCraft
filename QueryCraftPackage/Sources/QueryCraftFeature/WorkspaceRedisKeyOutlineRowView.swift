import AppKit

@MainActor
final class WorkspaceRedisKeyOutlineRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let typeBadgeView = RedisKeyTypeBadgeView()
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private var titleLeadingToIcon: NSLayoutConstraint!
    private var titleLeadingToBadge: NSLayoutConstraint!
    private var isKeyRow = false
    private var usesTypeBadge = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateSelectionAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(node: RedisKeyTreeNode) {
        switch node.content {
        case .prefix:
            isKeyRow = false
            usesTypeBadge = false
            iconView.image = NSImage(
                systemSymbolName: "folder",
                accessibilityDescription: nil
            )
            iconView.contentTintColor = .secondaryLabelColor
            iconView.isHidden = false
            typeBadgeView.isHidden = true
            titleLeadingToBadge.isActive = false
            titleLeadingToIcon.isActive = true
            countField.stringValue = node.keyCount.formatted()
            countField.isHidden = false
        case let .key(reference):
            isKeyRow = true
            if reference.type.sidebarBadgeText == nil {
                usesTypeBadge = false
                iconView.image = NSImage(
                    systemSymbolName: "key",
                    accessibilityDescription: nil
                )
                iconView.contentTintColor = .secondaryLabelColor
                iconView.isHidden = false
                typeBadgeView.isHidden = true
                titleLeadingToBadge.isActive = false
                titleLeadingToIcon.isActive = true
            } else {
                usesTypeBadge = true
                typeBadgeView.configure(type: reference.type)
                iconView.isHidden = true
                typeBadgeView.isHidden = false
                titleLeadingToIcon.isActive = false
                titleLeadingToBadge.isActive = true
            }
            countField.stringValue = ""
            countField.isHidden = true
        }
        titleField.stringValue = node.title
        toolTip = switch node.content {
        case let .prefix(path): path
        case let .key(reference):
            reference.type == .unknown
                ? reference.name
                : AppCopy.current.text(
                    "\(reference.name)\n类型：\(reference.type.rawValue)",
                    "\(reference.name)\nType: \(reference.type.rawValue)"
                )
        }
        setAccessibilityIdentifier(node.id)
        setAccessibilityLabel(node.title)
        setAccessibilityValue(
            node.reference.map { $0.type.rawValue }
                ?? node.keyCount.formatted()
        )
        updateSelectionAppearance()
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .regular
        )
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown

        typeBadgeView.translatesAutoresizingMaskIntoConstraints = false

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)

        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.alignment = .right
        countField.textColor = .tertiaryLabelColor
        countField.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize
        )
        countField.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )

        imageView = iconView
        textField = titleField
        addSubview(iconView)
        addSubview(typeBadgeView)
        addSubview(titleField)
        addSubview(countField)

        titleLeadingToIcon = titleField.leadingAnchor.constraint(
            equalTo: iconView.trailingAnchor,
            constant: 6
        )
        titleLeadingToBadge = titleField.leadingAnchor.constraint(
            equalTo: typeBadgeView.trailingAnchor,
            constant: 6
        )

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            typeBadgeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            typeBadgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            typeBadgeView.widthAnchor.constraint(equalToConstant: 42),
            typeBadgeView.heightAnchor.constraint(equalToConstant: 16),
            titleLeadingToIcon,
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor,
                constant: 4
            ),
            countField.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -6
            ),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func updateSelectionAppearance() {
        let isSelected = isKeyRow && backgroundStyle == .emphasized
        titleField.textColor = isSelected
            ? .alternateSelectedControlTextColor
            : .labelColor
        typeBadgeView.setSelected(isSelected && usesTypeBadge)
        if isKeyRow && !usesTypeBadge {
            iconView.contentTintColor = isSelected
                ? .alternateSelectedControlTextColor
                : .secondaryLabelColor
        }
    }
}
