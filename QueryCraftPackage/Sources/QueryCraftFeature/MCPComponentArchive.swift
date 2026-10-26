import Foundation
import Security

final class MCPComponentLock {
    private let descriptor: Int32
    init(directory: URL, filename: String = ".component.lock") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appending(path: filename).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MCPFailure("Cannot open component installation lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw MCPFailure(AppCopy.current.text("另一项组件操作正在进行，请稍后重试。", "Another component operation is in progress. Try again shortly."))
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

enum MCPComponentArchive {
    /// Validate central-directory paths and links before letting ditto extract.
    /// Framework symlinks are allowed, but no archive may write through a link.
    static func extract(_ archive: URL, into directory: URL, root: String) async throws {
        let file = try FileHandle(forReadingFrom: archive); defer { try? file.close() }
        let length = try file.seekToEnd()
        let tailLength = min(length, 65_557)
        try file.seek(toOffset: length - tailLength)
        let tail = try file.read(upToCount: Int(tailLength)) ?? Data()
        func integer(_ data: Data, _ offset: Int, _ count: Int) throws -> UInt64 {
            guard offset >= 0, offset + count <= data.count else { throw MCPFailure("Invalid ZIP directory.") }
            return (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
        }
        guard tail.count >= 22, let end = (0...(tail.count - 22)).reversed().first(where: {
            tail[$0] == 0x50 && tail[$0 + 1] == 0x4b && tail[$0 + 2] == 0x05 && tail[$0 + 3] == 0x06
        }), try integer(tail, end + 4, 4) == 0,
              try integer(tail, end + 8, 2) == integer(tail, end + 10, 2),
              end + 22 + Int(try integer(tail, end + 20, 2)) == tail.count else {
            throw MCPFailure("Invalid or multi-disk component ZIP.")
        }
        let count = Int(try integer(tail, end + 10, 2))
        let bytes = try integer(tail, end + 12, 4), offset = try integer(tail, end + 16, 4)
        guard count > 0, count < 20_000, bytes < 8_388_608, offset + bytes <= length - tailLength + UInt64(end) else {
            throw MCPFailure("Component archive exceeds directory limits.")
        }
        try file.seek(toOffset: offset)
        let central = try file.read(upToCount: Int(bytes)) ?? Data()
        var cursor = 0, total: UInt64 = 0
        var names: Set<String> = [], links: [String] = []
        for _ in 0..<count {
            guard try integer(central, cursor, 4) == 0x02014b50,
                  try integer(central, cursor + 8, 2) & 1 == 0 else { throw MCPFailure("Invalid or encrypted component ZIP.") }
            let nameCount = Int(try integer(central, cursor + 28, 2))
            let end = cursor + 46 + nameCount
            guard end <= central.count, let name = String(data: central[(cursor + 46)..<end], encoding: .utf8),
                  !name.contains("\\"), !name.hasPrefix("/"), !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  name.split(separator: "/").first.map(String.init) == root,
                  !name.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
                  names.insert(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted else {
                throw MCPFailure("Unsafe or duplicate component archive path.")
            }
            total += try integer(central, cursor + 24, 4)
            guard total <= 2_147_483_648 else { throw MCPFailure("Expanded component exceeds size limit.") }
            let mode = (try integer(central, cursor + 38, 4) >> 16) & 0xf000
            guard [0, 0x8000, 0x4000, 0xa000].contains(mode) else { throw MCPFailure("Unsupported component file type.") }
            if mode == 0xa000 { links.append(name) }
            cursor = end + Int(try integer(central, cursor + 30, 2)) + Int(try integer(central, cursor + 32, 2))
        }
        guard cursor == central.count else { throw MCPFailure("Invalid ZIP directory length.") }
        for link in links {
            guard !names.contains(where: { $0.hasPrefix(link + "/") }) else { throw MCPFailure("Archive writes through a symbolic link.") }
            let target = try await MCPProcess.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", archive.path, link])
            guard target.utf8.count < 4096, !target.hasPrefix("/"), !target.contains("\\") else { throw MCPFailure("Unsafe component link.") }
            let base = directory.appending(path: link).deletingLastPathComponent()
            let resolved = base.appending(path: target).standardizedFileURL.path
            guard resolved.hasPrefix(directory.appending(path: root).standardizedFileURL.path + "/") else { throw MCPFailure("Component link escapes its package.") }
        }
        _ = try await MCPProcess.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-xk", archive.path, directory.path], timeout: 120)
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw MCPFailure("Cannot inspect component staging.") }
        while let url = entries.nextObject() as? URL {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true,
               !url.resolvingSymlinksInPath().path.hasPrefix(directory.appending(path: root).resolvingSymlinksInPath().path + "/") {
                throw MCPFailure("Extracted component link escapes staging.")
            }
        }
    }

    static func verifySignature(_ url: URL, bundleIDs: Set<String>? = nil) throws {
        var code: SecStaticCode?, host: SecStaticCode?, info: CFDictionary?, hostInfo: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess,
              bundleIDs.map({ $0.contains(Bundle(url: url)?.bundleIdentifier ?? "") }) ?? true,
              SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &host) == errSecSuccess, let host,
              SecCodeCopySigningInformation(host, SecCSFlags(rawValue: kSecCSSigningInformation), &hostInfo) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let hostCert = ((hostInfo as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
              let cert = ((info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
              SecCertificateCopyData(hostCert) as Data == SecCertificateCopyData(cert) as Data else {
            throw MCPFailure(AppCopy.current.text("组件代码签名无效，或签名者与 QueryCraft 不匹配。", "Component code signature is invalid or its signer does not match QueryCraft."))
        }
    }
    static func replaceLink(at url: URL, with destination: String) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: destination)
        guard rename(temporary.path, url.path) == 0 else { throw MCPFailure("Cannot activate component version.") }
    }
}
