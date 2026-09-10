import AppKit

@MainActor
final class RedisKeyTypeBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var type = RedisKeyType.unknown
    private var isSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(type: RedisKeyType) {
        self.type = type
        label.stringValue = type.sidebarBadgeText ?? ""
        updateColors()
    }

    func setSelected(_ isSelected: Bool) {
        guard self.isSelected != isSelected else { return }
        self.isSelected = isSelected
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        label.lineBreakMode = .byClipping
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
        updateColors()
    }

    private func updateColors() {
        let tint = isSelected
            ? NSColor.alternateSelectedControlTextColor
            : type.badgeTintColor
        label.textColor = tint
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(
                isSelected ? 0.14 : 0.10
            ).cgColor
            layer?.borderColor = tint.withAlphaComponent(
                isSelected ? 0.72 : 0.28
            ).cgColor
        }
    }
}
