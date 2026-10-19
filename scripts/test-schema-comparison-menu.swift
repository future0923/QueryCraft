import AppKit
import SwiftUI
import QueryCraftFeature

// The compiler script appends the exact .commands modifiers from QueryCraftApp.
// A settings-only scene registers menus without presenting the user's workspace.
@MainActor final class MenuProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard let menu = NSApp.mainMenu else { fail("main menu absent"); return }
            func items(_ menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
            }
            let all = items(menu)
            func shortcut(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
                all.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask.intersection([.command, .shift, .control, .option]) == modifiers }
            }
            guard let comparison = shortcut("s", [.control, .option, .command]), comparison.action != nil,
                  all.filter({ $0.title == "Tools" || $0.title == "工具" }).count == 1 else {
                fail("comparison menu or shortcut absent/duplicated"); return
            }
            for (key, modifiers) in [("s", NSEvent.ModifierFlags.command), ("t", .command), ("k", .command), ("f", .command), ("e", [.command, .shift])] {
                guard shortcut(key, modifiers) != nil else { fail("existing shortcut lost: \(key)"); return }
            }
            print("PASS actual app command modifiers: one Tools menu, schema comparison action + control-option-command-S, existing save/new-tab/database/search/export shortcuts preserved")
            exit(0)
        }
    }
    func fail(_ reason: String) {
        FileHandle.standardError.write(Data("FAIL: \(reason)\n".utf8)); exit(1)
    }
}
@MainActor struct ProbeUpdater {
    let canCheckForUpdates = false
    func checkForUpdates() {}
}
