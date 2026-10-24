import XCTest
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor
final class MobileQueryModelTests: XCTestCase {
    private let first = CDatabaseQueryResult(columns: ["name", "nullable"], rows: [["你好", nil]])
    private let second = CDatabaseQueryResult(columns: ["other"], rows: [["new"]])

    func testInitialStateHasNoSuccessfulEmptyResult() {
        let model = MobileQueryModel(executor: ControlledExecutor())
        XCTAssertNil(model.result)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testSuccessfulQueryPreservesUnicodeAndNull() async throws {
        let driver = ControlledExecutor()
        let model = MobileQueryModel(executor: driver)
        let request = try XCTUnwrap(model.execute())
        await driver.waitForRequests(1)
        await driver.complete(0, result: .success(first))
        await request.value
        XCTAssertEqual(model.result, first)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testRefreshRetainsResultAndFailureOffersSameRetryChain() async throws {
        let driver = ControlledExecutor()
        let model = MobileQueryModel(executor: driver)
        let initial = try XCTUnwrap(model.execute())
        await driver.waitForRequests(1)
        await driver.complete(0, result: .success(first))
        await initial.value
        let revision = model.resultRevision
        let refresh = try XCTUnwrap(model.execute())
        await driver.waitForRequests(2)
        XCTAssertEqual(model.result, first)
        XCTAssertEqual(model.resultRevision, revision)
        XCTAssertTrue(model.isLoading)
        await driver.complete(1, result: .failure(TestFailure.expected))
        await refresh.value
        XCTAssertEqual(model.result, first)
        XCTAssertNotNil(model.errorMessage)
        let retry = try XCTUnwrap(model.execute())
        await driver.waitForRequests(3)
        await driver.complete(2, result: .success(second))
        await retry.value
        XCTAssertEqual(model.result, second)
        XCTAssertNil(model.errorMessage)
    }

    func testOnlySuccessfulEmptyQueryPublishesEmptyResult() async throws {
        let driver = ControlledExecutor()
        let model = MobileQueryModel(executor: driver)
        let task = try XCTUnwrap(model.execute())
        await driver.waitForRequests(1)
        XCTAssertNil(model.result)
        await driver.complete(0, result: .success(.init(columns: ["id"], rows: [])))
        await task.value
        XCTAssertEqual(model.result?.columns, ["id"])
        XCTAssertEqual(model.result?.rows.count, 0)
    }

    func testEndpointSwitchDiscardsLateCompletion() async throws {
        let driver = ControlledExecutor()
        let model = MobileQueryModel(executor: driver)
        let old = try XCTUnwrap(model.execute())
        await driver.waitForRequests(1)
        model.host = "new-endpoint.invalid"
        XCTAssertNil(model.result)
        let current = try XCTUnwrap(model.execute())
        await driver.waitForRequests(2)
        await driver.complete(1, result: .success(second))
        await current.value
        await driver.complete(0, result: .success(first))
        await old.value
        XCTAssertEqual(model.result, second)
        XCTAssertFalse(model.isLoading)
    }

    func testRepeatedRequestCannotOverwriteNewerResult() async throws {
        let driver = ControlledExecutor()
        let model = MobileQueryModel(executor: driver)
        let old = try XCTUnwrap(model.execute())
        await driver.waitForRequests(1)
        let current = try XCTUnwrap(model.execute())
        await driver.waitForRequests(2)
        await driver.complete(1, result: .success(second))
        await current.value
        await driver.complete(0, result: .failure(TestFailure.expected))
        await old.value
        XCTAssertEqual(model.result, second)
        XCTAssertNil(model.errorMessage)
    }

    func testCancelRetainsExistingResultAndRejectsLateSuccess() async throws {
        let driver = ControlledExecutor()
        let model = MobileQueryModel(executor: driver)
        let initial = try XCTUnwrap(model.execute())
        await driver.waitForRequests(1)
        await driver.complete(0, result: .success(first))
        await initial.value
        let next = try XCTUnwrap(model.execute())
        await driver.waitForRequests(2)
        model.cancel()
        XCTAssertFalse(model.isLoading)
        await driver.complete(1, result: .success(second))
        await next.value
        XCTAssertEqual(model.result, first)
        XCTAssertNil(model.errorMessage)
    }

    func testUnchangedDatabaseDoesNotCancelAndHistoryUsesExecutedSQL() async throws {
        let driver = ControlledExecutor()
        let current = MobileQueryModel(executor: driver)
        current.database = "db"; current.sql = "SELECT 1"
        let task = try XCTUnwrap(current.execute())
        await driver.waitForRequests(1)
        current.database = "db"
        current.sql = "SELECT 2"
        XCTAssertTrue(current.isLoading)
        await driver.complete(0, result: .success(first)); await task.value
        XCTAssertEqual(current.lastExecutedSQL, "SELECT 1")
        XCTAssertEqual(current.lastExecutedDatabase, "db")
        XCTAssertEqual(current.sql, "SELECT 2")
        XCTAssertNotNil(current.result)
    }

    func testInvalidInputsDoNotExecute() {
        let model = MobileQueryModel(executor: ControlledExecutor())
        model.port = "65536"
        XCTAssertNil(model.execute())
        model.port = "3306"
        model.sql = "  \n "
        XCTAssertNil(model.execute())
        model.sql = "SELECT 1"
        model.host = " "
        XCTAssertNil(model.execute())
    }
}

private enum TestFailure: Error { case expected }

private actor ControlledExecutor: MobileQueryExecuting {
    private var requests: [CheckedContinuation<CDatabaseQueryResult, any Error>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func execute(configuration: MobileSQLConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        // Deliberately ignores task cancellation to exercise late replies from C drivers.
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, result: Result<CDatabaseQueryResult, any Error>) {
        let continuation = requests[index]
        requests[index] = nil
        continuation?.resume(with: result)
    }
}
