import AppKit
import CodeEditTextView

/// A snippet owns one real selection. Other unfinished stops are only hints;
/// editing within a stop (including deleting it to an empty anchor) preserves navigation.
@MainActor
final class SQLSnippetSession {
    private struct Placeholder {
        var range: SQLSourceRange
        var isFilled = false
    }

    static let emphasisGroup = "QueryCraft.SQLSnippetPlaceholders"
    static let currentEmphasisGroup = "QueryCraft.SQLSnippetCurrentPlaceholder"

    private var placeholders: [Placeholder] = []
    private(set) var currentIndex = 0
    private var exitLocation = 0
    private var lastEmphases: [Emphasis] = []
    private var lastCurrentEmphases: [Emphasis] = []
    private var appearanceObservation: NSKeyValueObservation?
    private weak var textView: TextView?

    var placeholderRanges: [SQLSourceRange] { placeholders.map(\.range) }
    var isActive: Bool { textView != nil && !placeholders.isEmpty }

    var highlightedRanges: [SQLSourceRange] {
        let selection = textView?.selectedRange()
        let editing = editingIndex
        return placeholders.enumerated().compactMap { index, placeholder in
            guard !placeholder.isFilled,
                  placeholder.range.length > 0,
                  placeholder.range.nsRange != selection,
                  index != editing
            else { return nil }
            return placeholder.range
        }
    }

    /// A caret or partial selection inside a stop gets a border without covering its text.
    private var editingIndex: Int? {
        guard let selection = textView?.selectedRange(),
              selection.location != NSNotFound
        else { return nil }
        let selected = SQLSourceRange(selection)
        if placeholders.indices.contains(currentIndex),
           placeholders[currentIndex].range.contains(selected) {
            return currentIndex
        }
        return placeholders.firstIndex { $0.range.contains(selected) }
    }

    func start(
        textView: TextView,
        placeholderRanges: [SQLSourceRange],
        exitLocation: Int? = nil
    ) {
        end()
        let textLength = (textView.string as NSString).length
        guard !placeholderRanges.isEmpty,
              placeholderRanges.allSatisfy({
                  $0.location >= 0 && $0.length > 0 && $0.upperBound <= textLength
              }),
              zip(placeholderRanges, placeholderRanges.dropFirst()).allSatisfy({
                  $0.upperBound <= $1.location
              })
        else { return }
        self.textView = textView
        placeholders = placeholderRanges.map { Placeholder(range: $0) }
        self.exitLocation = min(textLength, max(
            placeholderRanges.last?.upperBound ?? 0,
            exitLocation ?? placeholderRanges.last?.upperBound ?? 0
        ))
        appearanceObservation = textView.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateEmphasis() }
        }
        selectCurrentPlaceholder()
    }

    func end() {
        textView?.emphasisManager?.removeEmphases(for: Self.emphasisGroup)
        textView?.emphasisManager?.removeEmphases(for: Self.currentEmphasisGroup)
        appearanceObservation = nil
        textView = nil
        placeholders = []
        currentIndex = 0
        exitLocation = 0
        lastEmphases = []
        lastCurrentEmphases = []
    }

    func endIfTextViewChanged(_ textView: TextView) {
        guard isActive, self.textView !== textView else { return }
        end()
    }

    @discardableResult
    func jumpToNextPlaceholder() -> Bool {
        guard isActive else { return false }
        guard currentIndex + 1 < placeholders.count else {
            let view = textView
            let location = exitLocation
            end()
            view?.selectionManager.setSelectedRange(NSRange(location: location, length: 0))
            view?.scrollSelectionToVisible()
            return true
        }
        currentIndex += 1
        selectCurrentPlaceholder()
        return true
    }

    @discardableResult
    func jumpToPreviousPlaceholder() -> Bool {
        guard isActive else { return false }
        currentIndex = currentIndex > 0 ? currentIndex - 1 : placeholders.count - 1
        selectCurrentPlaceholder()
        return true
    }

    func textDidChange(in range: NSRange, replacementLength: Int) {
        guard isActive, range.location != NSNotFound,
              range.length > 0 || replacementLength > 0 else { return }
        let edit = SQLSourceRange(range)
        let delta = replacementLength - range.length

        // Only the active stop owns insertions on its boundaries. Adjacent stops must
        // not both grow. Internal edits may target any stop, e.g. after a mouse click.
        let owner: Int? = if range.length == 0 {
            placeholders[currentIndex].range.contains(edit)
                ? currentIndex
                : placeholders.firstIndex {
                    range.location > $0.range.location && range.location < $0.range.upperBound
                }
        } else {
            placeholders.firstIndex { $0.range.contains(edit) }
        }

        var updated = placeholders
        for index in placeholders.indices {
            let placeholder = placeholders[index].range
            if index == owner {
                updated[index].range = SQLSourceRange(
                    location: placeholder.location,
                    length: placeholder.length + delta
                )
                updated[index].isFilled = true
            } else if range.upperBound <= placeholder.location {
                updated[index].range = SQLSourceRange(
                    location: placeholder.location + delta,
                    length: placeholder.length
                )
            } else if placeholder.upperBound > range.location {
                // An edit crossing stop boundaries destroys the template structure.
                // End explicitly rather than keeping misleading or duplicate stops.
                end()
                return
            }
        }
        placeholders = updated
        if let owner { currentIndex = owner }
        if range.location <= exitLocation {
            exitLocation = range.upperBound >= exitLocation
                ? range.location + replacementLength
                : exitLocation + delta
        }
        updateEmphasis()
    }

    func selectionDidChange(to range: NSRange) {
        guard isActive, range.location != NSNotFound else { return }
        let selected = SQLSourceRange(range)
        if !placeholders[currentIndex].range.contains(selected),
           let index = placeholders.firstIndex(where: { $0.range.contains(selected) }) {
            currentIndex = index
        }
        // Ordinary navigation outside a stop keeps the session available. Tab resumes
        // from the last edited stop; Escape or advancing past the last stop exits it.
        updateEmphasis()
    }

    private func selectCurrentPlaceholder() {
        guard isActive else { return }
        textView?.selectionManager.setSelectedRange(placeholders[currentIndex].range.nsRange)
        textView?.scrollSelectionToVisible()
        updateEmphasis()
    }

    private func updateEmphasis() {
        guard let textView, let manager = textView.emphasisManager else { return }
        let appearance = textView.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var accent = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            accent = accent.usingColorSpace(.deviceRGB) ?? accent
        }
        let hints = highlightedRanges.map {
            Emphasis(range: $0.nsRange, style: .fill(
                color: accent.withAlphaComponent(isDark ? 0.16 : 0.10)
            ))
        }
        let current: [Emphasis]
        if let index = editingIndex,
           placeholders[index].range.length > 0 {
            current = [Emphasis(range: placeholders[index].range.nsRange, style: .fill(
                color: .clear,
                borderColor: accent.withAlphaComponent(isDark ? 0.85 : 0.75)
            ))]
        } else {
            current = []
        }
        if hints != lastEmphases {
            manager.replaceEmphases(hints, for: Self.emphasisGroup)
            lastEmphases = hints
        }
        if current != lastCurrentEmphases {
            manager.replaceEmphases(current, for: Self.currentEmphasisGroup)
            lastCurrentEmphases = current
        }
    }
}
