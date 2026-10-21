import Foundation
import QueryCraftMCPRuntime
@_spi(MCP) import QueryCraftFeature

@main
struct QueryCraftMCPMain {
    static func main() async {
        do {
            try await QueryCraftMCPApplication.run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            if CommandLine.arguments.contains("--authorize-credentials"), let failure = try? MCPHost.failure(error),
               let data = try? JSONEncoder().encode(["credential_error": failure.code]) {
                FileHandle.standardOutput.write(data)
            }
            FileHandle.standardError.write(Data("QueryCraft MCP: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
