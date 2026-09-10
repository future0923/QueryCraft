actor SQLCompletionWorker {
    func completions(
        for request: SQLCompletionEngine.Request
    ) throws -> SQLCompletionResult? {
        try SQLCompletionEngine.completions(for: request)
    }
}
