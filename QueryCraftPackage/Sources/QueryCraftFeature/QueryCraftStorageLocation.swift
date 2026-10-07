import Foundation

/// Files that must be private to one app build live below this directory.
/// The released app keeps the historical `QueryCraft` location; the local
/// development build uses a separate directory so both apps can run together.
enum QueryCraftStorageLocation {
    static var applicationSupportDirectory: URL {
        let base = URL.applicationSupportDirectory
        return base.appending(
            path: directoryName,
            directoryHint: .isDirectory
        )
    }

    private static var directoryName: String {
        Bundle.main.bundleIdentifier == "io.github.future0923.QueryCraft.Dev"
            ? "QueryCraftDev"
            : "QueryCraft"
    }
}
