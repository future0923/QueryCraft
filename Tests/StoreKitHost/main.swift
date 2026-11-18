import AppKit

// An isolated host for the production StoreKit adapter. Never starts the app,
// sync engine, license service, or database layer.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
// Product.purchase requires a window anchor even with SKTestSession dialogs
// disabled. This is confined to the test app, never production UI.
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "QueryCraft · StoreKit local tests"
window.makeKeyAndOrderFront(nil)
application.run()
