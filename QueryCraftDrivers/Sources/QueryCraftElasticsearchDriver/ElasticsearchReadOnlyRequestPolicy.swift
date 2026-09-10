import QueryCraftFeature

enum ElasticsearchReadOnlyRequestPolicy {
    static func validate(_ request: WorkspaceRequest) throws {
        try validate(request, policy: .readOnly)
    }

    static func validate(_ request: WorkspaceRequest, policy: WorkspaceRequestExecutionPolicy) throws {
        try validateRelativePath(request.path)
        do { try WorkspaceRequestClassifier.validate(request, policy: policy) }
        catch {
            throw ElasticsearchError.unsupportedRequest("\(request.method.rawValue) \(request.path)")
        }
    }

    static func validateRelativePath(_ path: String) throws {
        do { try WorkspaceReadOnlyRequestValidator.validateRelativePath(path) }
        catch { throw ElasticsearchError.invalidRelativePath }
    }
}
