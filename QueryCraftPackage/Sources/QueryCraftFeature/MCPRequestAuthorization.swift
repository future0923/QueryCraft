import Foundation

enum MCPRequestAuthorization {
    static func index(_ path: String) -> String? {
        URLComponents(string: path)?.path.split(separator: "/").first.map(String.init)
    }

    static func validate(_ request: WorkspaceRequest, allowed: Set<String>?) throws {
        try validateScoped(request, allowed: allowed)
    }
}
