import Foundation

protocol CredentialStore: Sendable {
    func password(for profileID: UUID) async throws -> String?
    func save(password: String, for profileID: UUID) async throws
    func delete(for profileID: UUID) async throws
}
