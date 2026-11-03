import AppKit
import SwiftUI
import Testing
@testable import QueryCraftFeature

@MainActor struct WorkspaceCanvasTests {
    @Test func nativeTitlebarBackgroundTracksAppearanceWithoutChangingWindowGeometry() async throws {
        let window = WorkspaceWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.configureTitlebarBackground()
        let frame = window.frame
        #expect(window.titlebarAppearsTransparent)
        for name in [NSAppearance.Name.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .aqua] {
            window.appearance = NSAppearance(named: name)
            // KVO callbacks enqueue their UI update on the main actor.
            try await Task.sleep(for: .milliseconds(30))
            if #available(macOS 26.0, *) {
                #expect(window.titlebarAppearsTransparent == (name == .aqua))
            } else {
                #expect(window.titlebarAppearsTransparent)
            }
            #expect(window.frame == frame)
            #expect(window.styleMask.contains(.fullSizeContentView))
        }
    }

    @Test func dynamicNativeCanvasIsBlackIncludingHighContrastAndRetainsLightSurfaces() throws {
        for name in [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for color in [NSColor.queryCraftCanvas, .queryCraftWindowCanvas, .queryCraftPanelCanvas] {
                    let rgb = color.usingColorSpace(.sRGB)
                    #expect(rgb?.redComponent == 0 && rgb?.greenComponent == 0 && rgb?.blueComponent == 0)
                    #expect(rgb?.alphaComponent == 1)
                }
            }
        }
        let light = try #require(NSAppearance(named: .aqua))
        light.performAsCurrentDrawingAppearance {
            #expect(NSColor.queryCraftCanvas.usingColorSpace(.sRGB) == NSColor.textBackgroundColor.usingColorSpace(.sRGB))
            #expect(NSColor.queryCraftWindowCanvas.usingColorSpace(.sRGB) == NSColor.windowBackgroundColor.usingColorSpace(.sRGB))
        }
    }
    @Test func expandedNativeSplitDrawsBlackInSidebarAndContent() async throws {
        let split = WorkspaceMainSplitViewController(sidebar: AnyView(Color.clear), detail: AnyView(Color.clear), inspector: AnyView(Color.clear), showsSidebar: true, showsInspector: false, sidebarMinimumWidth: 180, sidebarMaximumWidth: 600, detailMinimumWidth: 520, inspectorMinimumWidth: 240)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1400, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua); window.contentViewController = split
        split.splitView.autosaveName = nil
        split.view.frame = .init(x: 0, y: 0, width: 1400, height: 700)
        window.setContentSize(.init(width: 1400, height: 700))
        split.splitView.frame = .init(x: 0, y: 0, width: 1400, height: 700)
        split.splitView.adjustSubviews()
        try await Task.sleep(for: .milliseconds(150))
        split.splitView.adjustSubviews(); split.view.layoutSubtreeIfNeeded()
        defer { window.contentViewController = nil }
        for item in split.splitViewItems.prefix(2) {
            let view = item.viewController.view
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            #expect(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0)
            #expect(color.alphaComponent == 1)
        }
    }

    @Test func titledSplitPaintsSidebarSafeAreaAcrossAppearanceAndVisibilityChanges() async throws {
        let split = WorkspaceMainSplitViewController(sidebar: AnyView(Color.clear), detail: AnyView(Color.clear), inspector: AnyView(Color.clear), showsSidebar: true, showsInspector: false, layoutIdentifier: "canvas-" + UUID().uuidString, sidebarMinimumWidth: 240, sidebarMaximumWidth: 600, detailMinimumWidth: 520, inspectorMinimumWidth: 240)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "CanvasTitlebarTest")
        window.backgroundColor = .queryCraftWindowCanvas
        window.contentViewController = split
        split.splitView.autosaveName = nil
        defer { window.contentViewController = nil }

        for appearance in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            split.splitViewItems[0].isCollapsed = true
            split.splitViewItems[0].isCollapsed = false
            split.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let view = split.splitViewItems[0].viewController.view
            #expect(view.safeAreaInsets.top > 0)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Sample the titlebar inset and the ordinary sidebar content; a
            // borderless window or a centre-only sample misses the white corner.
            for y in [2, bitmap.pixelsHigh / 2] {
                let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB))
                if appearance == .darkAqua {
                    #expect(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0)
                    #expect(color.alphaComponent == 1)
                } else {
                    #expect(color.alphaComponent == 0)
                }
            }
        }
    }
}
