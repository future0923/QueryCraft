import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

/// Opt-in acceptance on the connected phone. Credentials stay in its Keychain.
@MainActor final class MobilePhysicalSQLAcceptanceTests: XCTestCase {
    func testPhysicalSQLConnectionPreflight() async throws {
        try authorize()
        let profiles = try MobileLibraryRepository().load().profiles.filter { $0.driver == .mysql || $0.driver == .postgresql }
        var report: [String] = []
        for driver in [MobileDriver.mysql, .postgresql] {
            let candidates = profiles.filter { $0.driver == driver }
            report.append("\(driver.rawValue): saved profiles=\(candidates.count)")
            for profile in candidates {
                let password = try MobileKeychainStore().password(for: profile.id)
                guard !profile.requiresPassword || password != nil else {
                    report.append("profile=\(profile.id): missing saved credential"); continue
                }
                let config = profile.configuration(password: password)
                do {
                    let result = try await read(config, "SELECT 1 AS physical_probe")
                    XCTAssertEqual(result.rows, [["1"]])
                    report.append("profile=\(profile.id): SELECT 1 passed; database configured=\(!profile.database.isEmpty)")
                } catch {
                    // Never include connection configuration or credentials in attachments.
                    report.append("profile=\(profile.id): connection failed (\(String(describing: type(of: error))))")
                }
            }
        }
        attach(report.joined(separator: "\n"), name: "physical-sql-preflight")
    }

    private func authorize() throws {
        guard ProcessInfo.processInfo.environment["QUERYCRAFT_PHYSICAL_SQL_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Physical SQL acceptance requires explicit user authorization")
        }
    }
    private func read(_ config: MobileSQLConfiguration, _ sql: String) async throws -> CDatabaseQueryResult {
        if config.driver == .postgresql { return try await MobilePostgreSQLExecutor().execute(configuration: config, sql: sql) }
        return try await MobileMariaDBExecutor().execute(configuration: config, sql: sql)
    }
    private func attach(_ text: String, name: String) {
        let a = XCTAttachment(string: text); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
