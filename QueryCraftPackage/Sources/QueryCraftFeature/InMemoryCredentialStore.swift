import Foundation

actor InMemoryCredentialStore: CredentialStore {
    private var passwords: [UUID: String] = [:]

    init(passwords: [UUID: String] = [:]) {
        self.passwords = passwords
    }

    func password(for profileID: UUID) async throws -> String? {
        passwords[profileID]
    }

    func save(password: String, for profileID: UUID) async throws {
        passwords[profileID] = password
    }

    func delete(for profileID: UUID) async throws {
        passwords[profileID] = nil
    }
}
