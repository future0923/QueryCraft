actor WorkspaceElasticsearchResponseConversionWorker {
    func analyze(from response: WorkspaceRequestExecutionResult, maximumRows: Int,
                 parsed: ElasticsearchConsoleParsedRequest, source: String) throws
        -> (output: WorkspaceElasticsearchConsoleOutput, details: WorkspaceElasticsearchResponseDetails) {
        let converted = try output(from: response, maximumRows: maximumRows)
        let displayedRows: Int?
        if case .grid(let page) = converted { displayedRows = page.rowCount } else { displayedRows = nil }
        let details = try WorkspaceElasticsearchResponseDetails.read(response: response,
            displayedRows: displayedRows, parsed: parsed, source: source)
        return (converted, details)
    }

    func output(
        from response: WorkspaceRequestExecutionResult,
        maximumRows: Int
    ) throws -> WorkspaceElasticsearchConsoleOutput {
        try Task.checkCancellation()
        let output: WorkspaceElasticsearchConsoleOutput
        do {
            output = try ElasticsearchConsoleResponseConverter.output(from: response, maximumRows: maximumRows)
        } catch is CancellationError { throw CancellationError() }
        catch { output = .json(String(decoding: response.body, as: UTF8.self)) }
        try Task.checkCancellation()
        return output
    }
}
