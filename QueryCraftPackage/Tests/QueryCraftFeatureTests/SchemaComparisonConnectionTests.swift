import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QueryCraftFeature

private actor DatabaseListFixture: SchemaComparisonDatabaseListing {
    var configurations: [DatabaseConnectionConfiguration] = []
    var failure = false
    var gate: CatalogPhaseGate?
    let started = CatalogPhaseGate()
    func fail(_ value: Bool) { failure = value }
    func suspend(_ value: CatalogPhaseGate?) { gate = value }
    func databases(configuration: DatabaseConnectionConfiguration) async throws -> [String] {
        configurations.append(configuration)
        let blocked = gate
        await started.open()
        if let blocked { await blocked.wait() }
        if failure { throw SchemaComparisonError.invalidDatabase }
        // Deliberately ignores cancellation, to verify revision guards.
        return [configuration.host + "_db", configuration.host + "_db"]
    }
}

@MainActor
struct SchemaComparisonEndpointDraftTests {
    private func profile(_ name: String, stored: Bool = false) -> ConnectionProfile {
        .init(id: UUID(), name: name, groupID: nil, host: name, port: 3306, username: "reader",
              defaultDatabase: nil, tlsMode: .disabled, storesCredential: stored, createdAt: .now)
    }
    private func draft(_ profile: ConnectionProfile, loader: DatabaseListFixture,
                       credentials: InMemoryCredentialStore = .init()) -> SchemaComparisonEndpointDraft {
        .init(value: .init(profileID: profile.id), profile: profile, credentials: credentials, loader: loader)
    }

    @Test func listsDatabasesWithoutImplicitlyChoosingOne() async {
        let loader = DatabaseListFixture()
        let d = draft(profile("one"), loader: loader)
        #expect(!d.canCompare)
        d.reloadDatabases(); await d.waitForDatabases()
        #expect(d.phase == .ready && d.databases == ["one_db"])
        #expect(d.database.isEmpty && !d.canCompare)
        d.database = "one_db"
        #expect(d.canCompare)
        #expect(await loader.configurations.first?.database == nil)
    }

    @Test func switchingConnectionsRejectsLateResultsAndClearsSecrets() async {
        let loader = DatabaseListFixture()
        let gate = CatalogPhaseGate()
        await loader.suspend(gate)
        let d = draft(profile("one"), loader: loader)
        d.password = "temporary"
        d.database = "old_db"
        d.reloadDatabases(); await loader.started.wait()
        await loader.suspend(nil)
        let second = profile("two")
        d.selectProfile(second)
        await d.waitForDatabases()
        #expect(d.value.profileID == second.id && d.password.isEmpty && d.database.isEmpty)
        #expect(d.databases == ["two_db"])
        await gate.open()
        // The old continuation is already canceled; wait for a main-actor turn.
        await Task.yield()
        #expect(d.databases == ["two_db"] && d.phase == .ready)
    }

    @Test func savedCredentialAndExplicitPasswordAreAppliedToSelectedProfile() async throws {
        let p = profile("one", stored: true)
        let loader = DatabaseListFixture()
        let credentials = InMemoryCredentialStore(passwords: [p.id: "saved"])
        let d = draft(p, loader: loader, credentials: credentials)
        d.reloadDatabases(); await d.waitForDatabases()
        #expect(await loader.configurations.last?.password == "saved")
        d.password = "override"
        #expect(d.phase == .idle && d.databases.isEmpty)
        d.reloadDatabases(); await d.waitForDatabases()
        #expect(await loader.configurations.last?.password == "override")
        #expect(try await credentials.password(for: p.id) == "saved")
    }

    @Test func failedRefreshKeepsSameConnectionChoicesAndCanRetry() async {
        let loader = DatabaseListFixture()
        let d = draft(profile("one"), loader: loader)
        d.reloadDatabases(); await d.waitForDatabases()
        d.database = "one_db"
        await loader.fail(true)
        d.reloadDatabases()
        #expect(d.phase == .loading && d.databases == ["one_db"])
        await d.waitForDatabases()
        #expect(d.phase == .failed && d.errorMessage != nil && d.database == "one_db")
        await loader.fail(false)
        d.reloadDatabases(); await d.waitForDatabases()
        #expect(d.phase == .ready && d.errorMessage == nil && d.databases == ["one_db"])
    }

    @Test func closeRejectsLateDiscoveryAndClearsPassword() async {
        let loader = DatabaseListFixture()
        let gate = CatalogPhaseGate()
        await loader.suspend(gate)
        let d = draft(profile("one"), loader: loader)
        d.password = "temporary"
        d.reloadDatabases(); await loader.started.wait()
        d.close()
        await gate.open(); await Task.yield()
        #expect(d.phase == .idle && d.databases.isEmpty && d.password.isEmpty)
    }

    @Test func databaseDiscoveryClosesItsSessionAndDoesNotSelectADatabase() async throws {
        let session = InMemoryWorkspaceSession(databases: ["one", "two"])
        let factory = SingleDatabaseListSessionFactory(session: session)
        let loader = SchemaComparisonDatabaseLoader(sessionFactory: factory)
        let names = try await loader.databases(configuration: .init(host: "localhost", port: 3306,
            username: "reader", password: nil, database: "inaccessible_default", tlsMode: .disabled))
        #expect(names == ["one", "two"])
        #expect(await !session.isConnected())
        #expect(await factory.configuration?.database == nil)
    }

    @Test func tableDiscoveryReadsTablesAndViewsInTheSelectedDatabaseAndCloses() async throws {
        let session = InMemoryWorkspaceSession(databases: ["source"], objectsByDatabase: ["source": [
            .init(name: "orders", kind: .table), .init(name: "report", kind: .view),
            .init(name: "odd,table", kind: .table)
        ]])
        let factory = SingleDatabaseListSessionFactory(session: session)
        let names = try await SchemaComparisonTableLoader(sessionFactory: factory).tables(configuration: .init(
            host: "localhost", port: 3306, username: "reader", password: nil, database: "source", tlsMode: .disabled))
        #expect(names == ["odd,table", "orders", "report"])
        #expect(await factory.configuration?.database == "source")
        #expect(await !session.isConnected())
    }

    @Test func tableDiscoveryRejectsAnUnselectedDatabaseWithoutOpeningASession() async {
        let session = InMemoryWorkspaceSession(databases: [])
        let factory = SingleDatabaseListSessionFactory(session: session)
        do {
            _ = try await SchemaComparisonTableLoader(sessionFactory: factory).tables(configuration: .init(
                host: "localhost", port: 3306, username: "reader", password: nil, database: nil, tlsMode: .disabled))
            Issue.record("Missing database must fail before connecting")
        } catch { }
        #expect(await factory.configuration == nil)
    }
}

private actor SingleDatabaseListSessionFactory: WorkspaceSessionFactory {
    let session: any WorkspaceSession
    var configuration: DatabaseConnectionConfiguration?
    init(session: any WorkspaceSession) { self.session = session }
    func makeSession(configuration: DatabaseConnectionConfiguration) async -> any WorkspaceSession {
        self.configuration = configuration
        return session
    }
}

@MainActor
@Suite(.serialized)
struct SchemaComparisonConnectionControlsTests {
    @Test func resultsSplitPreservesTheChosenProportionAcrossWindowSizesAndReopening() async throws {
        let suite = "QueryCraft.SchemaSplitTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SchemaComparisonResultsSplitViewController(objects: AnyView(Color.clear), detail: AnyView(Color.clear), defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 900))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutSubtreeIfNeeded()
        func fraction() -> CGFloat { controller.objects.view.frame.height / (controller.splitView.bounds.height - controller.splitView.dividerThickness) }
        #expect(abs(fraction() - 0.6) < 0.01)
        controller.splitView.setPosition((controller.splitView.bounds.height - controller.splitView.dividerThickness) * 0.48, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(fraction() - 0.48) < 0.01)
        window.setContentSize(NSSize(width: 1200, height: 1100))
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutSubtreeIfNeeded()
        #expect(abs(fraction() - 0.48) < 0.01)
        #expect(abs(defaults.double(forKey: "schemaComparison.resultsObjectFraction") - 0.48) < 0.01)
        let restored = SchemaComparisonResultsSplitViewController(objects: AnyView(Color.clear), detail: AnyView(Color.clear), defaults: defaults)
        window.contentViewController = restored
        window.setContentSize(NSSize(width: 940, height: 500))
        try await Task.sleep(for: .milliseconds(100))
        restored.view.layoutSubtreeIfNeeded()
        #expect(abs(restored.objects.view.frame.height / (restored.splitView.bounds.height - restored.splitView.dividerThickness) - 0.48) < 0.01)
    }

    @Test func ddlProvidesNativeLineNumbersAndAnExplicitMissingSide() async throws {
        let host = NSHostingController(rootView: SchemaComparisonDDLPairView(source: "", target: "CREATE TABLE old_table (\n  id INT\n);", objectID: "old").frame(maxWidth: .infinity, maxHeight: .infinity))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 260), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 940, height: 260))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutSubtreeIfNeeded()
        let views = descendants(host.view)
        let missing = try #require(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "schemaComparisonSourceMissing" })
        #expect(!missing.isHidden && !missing.stringValue.isEmpty)
        let target = try #require(views.compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "schemaComparisonTargetDDL" })
        let scroll = try #require(target.enclosingScrollView)
        #expect(!scroll.isHidden && scroll.rulersVisible)
        #expect(target.visibleRect.width > 200 && target.visibleRect.height > 30)
        #expect(target.frame.width > 200)
        #expect(scroll.verticalRulerView is SchemaComparisonLineNumberRuler)
        #expect((scroll.verticalRulerView?.ruleThickness ?? 0) >= 38)
        host.rootView = SchemaComparisonDDLPairView(source: "", target: "CREATE TABLE other_table (\n  id INT\n);", objectID: "other").frame(maxWidth: .infinity, maxHeight: .infinity)
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.minX <= -scroll.contentView.contentInsets.left + 0.5)
        #expect(target.convert(target.textContainerOrigin, to: scroll).x > (scroll.verticalRulerView?.frame.maxX ?? 0))
    }

    @Test func ddlSplitBalancesInAWindowAndAllowsNativeResizing() async throws {
        let controller = SchemaComparisonDDLSplitViewController()
        controller.addPane(NSView()); controller.addPane(NSView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 240), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 940, height: 240))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutSubtreeIfNeeded()
        let split = controller.splitView
        let panes: [NSView] = controller.splitViewItems.map { $0.viewController.view }
        #expect(split.bounds.width >= 900)
        #expect(panes.count == 2 && abs(panes[0].frame.width - panes[1].frame.width) < 2)
        split.setPosition((split.bounds.width - split.dividerThickness) * 0.65, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(50))
        controller.view.layoutSubtreeIfNeeded()
        #expect(abs(panes[0].frame.width / (split.bounds.width - split.dividerThickness) - 0.65) < 0.01)
        window.setContentSize(NSSize(width: 1100, height: 240)); controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(panes.allSatisfy { $0.frame.width >= 180 })
    }
    @Test func nativeConnectionPopupSelectsDistinctIDsAndDisambiguatesDuplicateNames() throws {
        let profiles = [3306, 3307].map { port in
            ConnectionProfile(id: UUID(), name: "mysql", groupID: nil, host: "127.0.0.1", port: port,
                username: "reader", defaultDatabase: nil, tlsMode: .disabled, storesCredential: false, createdAt: .now)
        }
        var selected = profiles[0].id
        let host = NSHostingView(rootView: SchemaComparisonConnectionPicker(profiles: profiles,
            selection: selected, accessibilityIdentifier: "testConnection", select: { if let id = $0 { selected = id } }))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 40)
        host.layoutSubtreeIfNeeded()
        let popup = try #require(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
        #expect(popup.numberOfItems == 3 && popup.indexOfSelectedItem == 1)
        #expect(popup.itemTitle(at: 1).contains("3306") && popup.itemTitle(at: 2).contains("3307"))
        popup.selectItem(at: 2)
        #expect(popup.sendAction(popup.action, to: popup.target))
        #expect(selected == profiles[1].id)
        popup.selectItem(at: 1)
        popup.sendAction(popup.action, to: popup.target)
        #expect(selected == profiles[0].id)
    }

    @Test func nativeDatabaseComboSelectsLoadedNamesAndAllowsManualEntry() throws {
        var selected = ""
        let host = NSHostingView(rootView: SchemaComparisonDatabaseComboBox(text: Binding(get: { selected }, set: { selected = $0 }),
            databases: ["dev", "test"], accessibilityIdentifier: "testDatabase"))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
        host.layoutSubtreeIfNeeded()
        let box = try #require(descendants(host).compactMap { $0 as? NSComboBox }.first)
        #expect(box.numberOfItems == 2 && box.isEditable && box.placeholderString?.isEmpty == false)
        box.selectItem(at: 1); box.sendAction(box.action, to: box.target)
        #expect(selected == "test")
        box.stringValue = "manual_schema"; box.sendAction(box.action, to: box.target)
        #expect(selected == "manual_schema")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
