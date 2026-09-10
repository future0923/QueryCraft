import Foundation
import Testing
@testable import QueryCraftFeature

struct ConnectionProfileDraftTests {
    @Test func editingDraftCopiesEverySavedConnectionField() {
        let groupID = UUID()
        let profile = ConnectionProfile(
            id: UUID(),
            name: "Local PostgreSQL",
            groupID: groupID,
            databaseType: .postgresql,
            host: "db.internal.test",
            port: 15_432,
            username: "querycraft_editor",
            defaultDatabase: "saved_database",
            tlsMode: .required,
            storesCredential: true,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        let draft = ConnectionProfileDraft(
            profile: profile,
            password: "saved-password"
        )

        #expect(draft.name == profile.name)
        #expect(draft.groupID == groupID)
        #expect(draft.databaseType == .postgresql)
        #expect(draft.databaseProduct == .postgresql)
        #expect(draft.host == "db.internal.test")
        #expect(draft.port == 15_432)
        #expect(draft.username == "querycraft_editor")
        #expect(draft.password == "saved-password")
        #expect(draft.defaultDatabase == "saved_database")
        #expect(draft.tlsMode == .required)
        #expect(draft.savePassword)
    }

    @Test func createsTrimmedProfileWithoutPassword() throws {
        let id = UUID()
        let groupID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var draft = ConnectionProfileDraft()
        draft.name = "  Local MySQL  "
        draft.groupID = groupID
        draft.host = "  127.0.0.1  "
        draft.username = "  developer  "
        draft.defaultDatabase = "  querycraft  "

        let profile = try draft.makeProfile(id: id, createdAt: createdAt)

        #expect(profile.id == id)
        #expect(profile.name == "Local MySQL")
        #expect(profile.groupID == groupID)
        #expect(profile.databaseType == .mysql)
        #expect(profile.databaseProduct == .mysql)
        #expect(profile.host == "127.0.0.1")
        #expect(profile.port == 3306)
        #expect(profile.username == "developer")
        #expect(profile.defaultDatabase == "querycraft")
        #expect(profile.tlsMode == .verifyIdentity)
        #expect(profile.storesCredential == false)
        #expect(profile.createdAt == createdAt)
    }

    @Test func rejectsMissingName() {
        let draft = ConnectionProfileDraft()

        #expect(throws: ConnectionProfileValidationError.missingName) {
            try draft.makeProfile()
        }
    }

    @Test func rejectsOutOfRangePort() {
        var draft = ConnectionProfileDraft()
        draft.name = "Local MySQL"
        draft.port = 65_536

        #expect(throws: ConnectionProfileValidationError.invalidPort) {
            try draft.makeProfile()
        }
    }

    @Test func selectingPostgreSQLReplacesOnlyDatabaseDefaults() throws {
        var draft = ConnectionProfileDraft()
        draft.name = "Local PostgreSQL"

        draft.selectDatabaseType(.postgresql)

        #expect(draft.databaseType == .postgresql)
        #expect(draft.port == 5_432)
        #expect(draft.username == "postgres")
        let configuration = try draft.makeConnectionConfiguration()
        #expect(configuration.databaseType == .postgresql)
    }

    @Test func selectingDatabaseTypePreservesCustomEndpointValues() {
        var draft = ConnectionProfileDraft()
        draft.port = 15_432
        draft.username = "querycraft"

        draft.selectDatabaseType(.postgresql)

        #expect(draft.port == 15_432)
        #expect(draft.username == "querycraft")
    }

    @Test func apacheDorisAndSelectDBUseDorisConnectionDefaults() throws {
        let apacheDoris = ConnectionProfileDraft(databaseProduct: .apacheDoris)
        var selectDB = ConnectionProfileDraft(databaseProduct: .selectDB)
        selectDB.name = "SelectDB Cloud"

        #expect(apacheDoris.databaseType == .doris)
        #expect(apacheDoris.port == 9_030)
        #expect(apacheDoris.username == "root")
        let profile = try selectDB.makeProfile()
        #expect(profile.databaseType == .doris)
        #expect(profile.databaseProduct == .selectDB)
    }

    @Test func switchingBetweenDorisProductsKeepsSharedDefaults() {
        var draft = ConnectionProfileDraft(databaseProduct: .apacheDoris)

        draft.selectDatabaseProduct(.selectDB)

        #expect(draft.databaseType == .doris)
        #expect(draft.databaseProduct == .selectDB)
        #expect(draft.port == 9_030)
        #expect(draft.username == "root")
    }

    @Test func selectingDatabasePreservesSelectDBProductIdentity() {
        let configuration = DatabaseConnectionConfiguration(
            databaseProduct: .selectDB,
            host: "selectdb.example.com",
            port: 9_030,
            username: "root",
            password: nil,
            database: nil,
            tlsMode: .disabled
        )

        let selected = configuration.selecting(database: "analytics")

        #expect(selected.databaseType == .doris)
        #expect(selected.databaseProduct == .selectDB)
        #expect(selected.database == "analytics")
    }

    @Test func elasticsearchUsesDocumentConnectionDefaults() throws {
        var draft = ConnectionProfileDraft(databaseProduct: .elasticsearch)
        draft.name = "Local Elasticsearch"

        #expect(draft.databaseType == .elasticsearch)
        #expect(draft.port == 9_200)
        #expect(draft.username == "elastic")
        #expect(draft.defaultDatabase.isEmpty)
        #expect(draft.tlsMode == .disabled)
        #expect(draft.authenticationMethod == .usernamePassword)

        draft.authenticationMethod = .apiKey
        draft.password = "encoded-api-key"
        let configuration = try draft.makeConnectionConfiguration()
        #expect(configuration.authentication == .apiKey("encoded-api-key"))
        #expect(configuration.database == nil)

        let profile = try draft.makeProfile()
        #expect(profile.authenticationMethod == .apiKey)
        #expect(profile.storesCredential)
    }

    @Test func noAuthenticationDoesNotPersistAnElasticsearchSecret() throws {
        var draft = ConnectionProfileDraft(databaseProduct: .elasticsearch)
        draft.name = "Development Cluster"
        draft.authenticationMethod = .none
        draft.password = "unused"

        let configuration = try draft.makeConnectionConfiguration()
        let profile = try draft.makeProfile()

        #expect(configuration.authentication == .none)
        #expect(profile.authenticationMethod == .none)
        #expect(!profile.storesCredential)
    }

    @Test func leavingElasticsearchRestoresRelationalAuthentication() {
        var draft = ConnectionProfileDraft(databaseProduct: .elasticsearch)
        draft.authenticationMethod = .apiKey

        draft.selectDatabaseProduct(.mysql)

        #expect(draft.databaseType == .mysql)
        #expect(draft.authenticationMethod == .usernamePassword)
        #expect(draft.tlsMode == .verifyIdentity)
    }
}
