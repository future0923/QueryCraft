import Foundation
import QueryCraftFeature

@main
struct QueryCraftMCPMain {
    static func main() async {
        do {
            try await QueryCraftMCPApplication.run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("QueryCraft MCP: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
