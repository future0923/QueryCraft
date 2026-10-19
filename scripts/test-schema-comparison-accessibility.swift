import ApplicationServices
import Foundation

// AX actions target this test process only; they never move the mouse or post
// keyboard events. Running out of process exercises SwiftUI's real AX bridge.
guard (3...4).contains(CommandLine.arguments.count), let pid = Int32(CommandLine.arguments[1]), AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility permission or target arguments unavailable\n".utf8))
    exit(2)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 15)
var visited: [AXUIElement] = []
let deadline = Date().addingTimeInterval(15)
func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
    return result
}
func find(_ element: AXUIElement, _ id: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 24, Date() < deadline, visited.count < 500 else { return nil }
    guard !visited.contains(where: { CFEqual($0, element) }) else { return nil }
    visited.append(element)
    if id.hasPrefix("label:") {
        if value(element, kAXRoleAttribute) as? String == kAXButtonRole,
           (value(element, kAXTitleAttribute) as? String == String(id.dropFirst(6))
            || value(element, kAXDescriptionAttribute) as? String == String(id.dropFirst(6))) { return element }
    } else if value(element, kAXIdentifierAttribute) as? String == id { return element }
    for key in (depth == 0 ? [kAXWindowsAttribute] : [kAXChildrenAttribute, kAXRowsAttribute]) {
        for child in value(element, key) as? [AXUIElement] ?? [] {
            if let found = find(child, id, depth: depth + 1) { return found }
        }
    }
    return nil
}
guard let control = find(app, CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("AX control missing: \(CommandLine.arguments[2]); visited=\(visited.count), tree=\(visited.map { [value($0, kAXRoleAttribute), value($0, kAXIdentifierAttribute)] }), windows=\(String(describing: value(app, kAXWindowsAttribute)))\n".utf8)); exit(3)
}
let result = CommandLine.arguments.count == 4
    ? AXUIElementSetAttributeValue(control, kAXValueAttribute as CFString, CommandLine.arguments[3] as CFString)
    : AXUIElementPerformAction(control, kAXPressAction as CFString)
if result == .cannotComplete, CommandLine.arguments[2].contains("Export") {
    // A native save service may take longer than the AX messaging timeout.
    // The caller must verify that the actual save sheet appeared.
    exit(5)
}
guard result == .success else {
    FileHandle.standardError.write(Data("AX press error: \(result.rawValue)\n".utf8)); exit(4)
}
