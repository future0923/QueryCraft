import Foundation

struct WorkspaceSavedQueryActions {
    let open: @MainActor (SavedQuery.ID) -> Void
    let rename: @MainActor (SavedQuery.ID) -> Void
    let duplicate: @MainActor (SavedQuery.ID) -> Void
    let move: @MainActor (SavedQuery.ID, String?) -> Void
    let delete: @MainActor (SavedQuery.ID) -> Void
}
