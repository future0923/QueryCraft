import Foundation
import Security
import MachO

// Fixed entry point. Exec the canonical immutable version path so a running
// process never resolves framework resources through the mutable Current link.
func fail() -> Never {
    FileHandle.standardError.write(Data("QueryCraft MCP: no trusted runtime is active. Install or repair MCP in QueryCraft settings.\n".utf8))
    exit(1)
}
func certificate(_ url: URL) -> Data? {
    var code: SecStaticCode?, info: CFDictionary?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let cert = ((info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return nil }
    return SecCertificateCopyData(cert) as Data
}
var length: UInt32 = 0
_ = _NSGetExecutablePath(nil, &length)
var path = [CChar](repeating: 0, count: Int(length))
guard _NSGetExecutablePath(&path, &length) == 0 else { fail() }
let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
let root = executable.deletingLastPathComponent().deletingLastPathComponent()
let app = root.appending(path: "Current").resolvingSymlinksInPath()
guard app.path.hasPrefix(root.appending(path: "Versions").path + "/"),
      ["io.github.future0923.QueryCraft.MCP", "io.github.future0923.QueryCraft.MCP.Dev"].contains(Bundle(url: app)?.bundleIdentifier ?? ""),
      let own = certificate(executable), certificate(app) == own else { fail() }
let binary = app.appending(path: "Contents/MacOS/querycraft-mcp").path
var arguments = ([binary] + CommandLine.arguments.dropFirst()).map { strdup($0) } + [nil]
arguments.withUnsafeMutableBufferPointer { buffer in _ = execv(binary, buffer.baseAddress!) }
fail()
