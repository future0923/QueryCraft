import CryptoKit
import Foundation

/// Device-local file grants. These bookmarks never enter connection models,
/// exports, MCP responses or CloudKit records.
struct LocalFileAuthorization: Sendable {
    let directory: URL
    static var shared: Self {
        Self(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "QueryCraft/FileAuthorizations", directoryHint: .isDirectory))
    }

    func remember(_ url: URL, readOnly: Bool = true) throws {
        let active = url.startAccessingSecurityScopedResource()
        defer { if active { url.stopAccessingSecurityScopedResource() } }
        let options: URL.BookmarkCreationOptions = readOnly ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.withSecurityScope]
        let data = try url.bookmarkData(options: options,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let destination = bookmarkURL(for: url.path)
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func access(path: String, writable: Bool = false) throws -> Access {
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let bookmark = bookmarkURL(for: path)
        var url = requested
        var stale = false
        if FileManager.default.fileExists(atPath: bookmark.path) {
            do {
                url = try URL(resolvingBookmarkData: Data(contentsOf: bookmark),
                              options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
                // A moved/replaced key must be explicitly selected again. Never
                // silently authenticate using another path than the saved one.
                guard url.standardizedFileURL.path == requested.path else { throw AccessError.selectAgain }
            } catch { throw AccessError.selectAgain }
        }
        let access = Access(url: url)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw AccessError.selectAgain }
        if writable && !FileManager.default.isWritableFile(atPath: url.path) { throw AccessError.selectAgain }
        if stale { try remember(url, readOnly: !writable) }
        return access
    }

    private func bookmarkURL(for path: String) -> URL {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: hash + ".bookmark")
    }

    /// Immutable lease retained by the operation until all native file I/O ends.
    final class Access: Sendable {
        private let url: URL
        private let active: Bool
        init(url: URL) { self.url = url; active = url.startAccessingSecurityScopedResource() }
        deinit { if active { url.stopAccessingSecurityScopedResource() } }
    }

    enum AccessError: LocalizedError {
        case selectAgain
        var errorDescription: String? {
            AppCopy.current.text("无法访问本机文件或目录。请点“选择…”重新选择，授予此设备访问权限。",
                                 "Cannot access the local file or folder. Use Choose… to select it again and grant access on this device.")
        }
    }
}
