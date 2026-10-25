struct EditorColorChangeHistory {
    private var past: [EditorColorSettings] = []
    private var future: [EditorColorSettings] = []
    private var continuousKey: String?
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    mutating func finishContinuousChange() { continuousKey = nil }
    mutating func record(from current: EditorColorSettings, to next: EditorColorSettings, key: String? = nil) {
        guard next != current else { return }
        if key == nil || key != continuousKey {
            past.append(current)
            if past.count > 100 { past.removeFirst() }
        }
        continuousKey = key; future.removeAll()
    }
    mutating func undo(current: EditorColorSettings) -> EditorColorSettings? {
        guard let previous = past.popLast() else { return nil }
        finishContinuousChange(); future.append(current); return previous
    }
    mutating func redo(current: EditorColorSettings) -> EditorColorSettings? {
        guard let next = future.popLast() else { return nil }
        finishContinuousChange(); past.append(current); return next
    }
}
