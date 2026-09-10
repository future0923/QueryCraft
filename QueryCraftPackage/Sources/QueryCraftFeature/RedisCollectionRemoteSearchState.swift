import Observation

@MainActor
@Observable
final class RedisCollectionRemoteSearchState {
    var isPresented = false
    var draftText = ""
    var field = RedisCollectionSearchField.all
    var mode = RedisCollectionMatchMode.contains
    var isCaseSensitive = false
    private(set) var submittedSearch: RedisCollectionSearch?
    private(set) var revision = 0
    private(set) var focusRequest = 0

    func configure(for type: RedisKeyType) {
        let available = availableFields(for: type)
        if !available.contains(field) {
            field = available.first ?? .all
        }
    }

    func submit() {
        let text = draftText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        submittedSearch = text.isEmpty ? nil : RedisCollectionSearch(
            text: text,
            field: field,
            mode: mode,
            isCaseSensitive: isCaseSensitive
        )
        revision &+= 1
    }

    func clear() {
        draftText = ""
        submittedSearch = nil
        revision &+= 1
    }

    func present() {
        isPresented = true
        focusRequest &+= 1
    }

    func dismiss() {
        isPresented = false
    }

    func togglePresentation() {
        if isPresented {
            dismiss()
        } else {
            present()
        }
    }

    func availableFields(
        for type: RedisKeyType
    ) -> [RedisCollectionSearchField] {
        switch type {
        case .list: [.value]
        case .hash: [.all, .field, .value]
        case .set: [.member]
        case .sortedSet: [.all, .member, .score]
        case .string, .stream, .module, .unknown, .none: []
        }
    }
}
