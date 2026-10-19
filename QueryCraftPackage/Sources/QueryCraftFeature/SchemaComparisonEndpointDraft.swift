import Foundation
import Observation

protocol SchemaComparisonDatabaseListing: Sendable {
    func databases(configuration: DatabaseConnectionConfiguration) async throws -> [String]
}

struct SchemaComparisonDatabaseLoader: SchemaComparisonDatabaseListing {
    let sessionFactory: any WorkspaceSessionFactory

    func databases(configuration: DatabaseConnectionConfiguration) async throws -> [String] {
        let session = await sessionFactory.makeSession(configuration: configuration.selecting(database: nil))
        do {
            try Task.checkCancellation()
            // Preserve ownership until connect finishes, including after cancellation.
            let connecting = Task { try await session.connect() }
            try await connecting.value
            try Task.checkCancellation()
            let names = try await session.fetchDatabases()
            try Task.checkCancellation()
            await session.close()
            return names
        } catch {
            await session.close()
            throw error
        }
    }
}

/// Owns one side of the setup sheet. No edits reach the comparison until Compare.
@MainActor
@Observable
final class SchemaComparisonEndpointDraft {
    enum Phase { case idle, loading, ready, failed }
    private(set) var value: WorkspaceSchemaComparisonModel.Endpoint
    private(set) var profile: ConnectionProfile?
    private(set) var databases: [String] = []
    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let loader: any SchemaComparisonDatabaseListing
    @ObservationIgnored private let tableLoader: any SchemaComparisonTableListing
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()

    init(value: WorkspaceSchemaComparisonModel.Endpoint, profile: ConnectionProfile?,
         credentials: any CredentialStore, loader: any SchemaComparisonDatabaseListing,
         tableLoader: any SchemaComparisonTableListing = SchemaComparisonTableLoader(sessionFactory: DefaultWorkspaceSessionFactory())) {
        self.value = value
        self.profile = profile
        self.credentials = credentials
        self.loader = loader
        self.tableLoader = tableLoader
    }

    var database: String {
        get { value.database }
        set { value.database = newValue }
    }

    var password: String {
        get { value.password }
        set {
            guard value.password != newValue else { return }
            value.password = newValue
            invalidate()
        }
    }

    var canCompare: Bool {
        profile?.id == value.profileID && profile != nil
            && !value.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func selectProfile(_ newProfile: ConnectionProfile?) {
        guard newProfile != profile else { return }
        invalidate()
        profile = newProfile
        value = .init(profileID: newProfile?.id, database: newProfile?.defaultDatabase ?? "")
        if newProfile != nil { reloadDatabases() }
    }

    func reloadDatabases() {
        guard let profile else { return }
        task?.cancel()
        let request = UUID()
        revision = request
        let input = value
        phase = .loading
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let secret: String?
                if !input.password.isEmpty { secret = input.password }
                else if profile.storesCredential { secret = try await credentials.password(for: profile.id) }
                else { secret = nil }
                try Task.checkCancellation()
                let names = try await loader.databases(configuration: .init(
                    databaseType: profile.databaseType, databaseProduct: profile.databaseProduct,
                    host: profile.host, port: profile.port, authentication: profile.authentication(secret: secret),
                    database: nil, tlsMode: profile.tlsMode
                ))
                try Task.checkCancellation()
                guard revision == request else { return }
                databases = Array(Set(names)).sorted()
                phase = .ready
            } catch {
                guard revision == request else { return }
                errorMessage = error.localizedDescription
                phase = .failed
            }
            if revision == request { task = nil }
        }
    }

    func tableNames() async throws -> [String] {
        guard let profile, canCompare else { throw SchemaComparisonError.invalidDatabase }
        let input = value
        let secret: String?
        if !input.password.isEmpty { secret = input.password }
        else if profile.storesCredential { secret = try await credentials.password(for: profile.id) }
        else { secret = nil }
        try Task.checkCancellation()
        let names = try await tableLoader.tables(configuration: .init(
            databaseType: profile.databaseType, databaseProduct: profile.databaseProduct,
            host: profile.host, port: profile.port, authentication: profile.authentication(secret: secret),
            database: input.database, tlsMode: profile.tlsMode))
        try Task.checkCancellation()
        return names
    }

    func applyConfiguration(_ endpoint: SchemaComparisonConfiguration.Endpoint, profile: ConnectionProfile?) {
        invalidate()
        self.profile = profile
        value = .init(profileID: profile?.id, database: endpoint.database)
        if profile != nil { reloadDatabases() }
    }

    func waitForDatabases() async { await task?.value }

    func close() {
        invalidate()
        value.password = ""
    }

    private func invalidate() {
        revision = UUID()
        task?.cancel()
        task = nil
        databases = []
        phase = .idle
        errorMessage = nil
    }
}
