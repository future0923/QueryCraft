import Foundation
import Testing
#if os(iOS)
import QueryCraftMobileCore
@testable import QueryCraftMobileProof
#else
@testable import QueryCraftFeature
#endif

@MainActor struct SQLExecutionBatchRunnerTests {
    private enum Failure: Error { case expected }
    @Test func executesInSourceOrderAndNeverRunsTheSuffixAfterFailure() async throws {
        let statements = (0..<3).map { index in
            SQLExecutionStatement(index: index, source: .init(revision: .init(1), text: "SELECT 1;"),
                range: .init(location: 0, length: 9), kind: .read)
        }
        var seen: [Int] = []
        do {
            try await SQLExecutionBatchRunner.run(statements) { statement in
                seen.append(statement.index)
                if statement.index == 1 { throw Failure.expected }
            }
            Issue.record("The first failure must stop execution")
        } catch Failure.expected { }
        #expect(seen == [0, 1])
    }

    @Test func checksCancellationBeforeTheFirstCallback() async {
        let statement = SQLExecutionStatement(index: 0, source: .init(revision: .init(1), text: "SELECT 1;"),
            range: .init(location: 0, length: 9), kind: .read)
        var called = false
        let task = Task { @MainActor in
            do { try await SQLExecutionBatchRunner.run([statement]) { _ in called = true } }
            catch is CancellationError { }
            catch { Issue.record(error) }
        }
        task.cancel(); await task.value
        #expect(called == false)
    }
}
