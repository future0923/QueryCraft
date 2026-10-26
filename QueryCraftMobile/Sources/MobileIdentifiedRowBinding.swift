import SwiftUI

extension Binding {
    /// Form inputs can outlive a removed row during focus/keyboard updates.
    /// Resolve stable identity on every access; never retain an array index.
    @MainActor func identifiedRow<Row: Identifiable & Sendable>(_ snapshot: Row) -> Binding<Row> where Value == [Row], Row.ID: Sendable {
        let id = snapshot.id
        return Binding<Row>(
            get: { wrappedValue.first { $0.id == id } ?? snapshot },
            set: { value in
                guard value.id == id, let index = wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                wrappedValue[index] = value
            }
        )
    }
}
