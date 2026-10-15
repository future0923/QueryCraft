import AppKit
import SwiftUI
import QuartzCore
@testable import QueryCraftFeature

@MainActor
@main final class ImportScrollBenchmark: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = ImportScrollBenchmark()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
    let isolation = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    var window: NSWindow?
    var host: NSView?
    var mapping: NSScrollView?
    var preview: NSScrollView?
    var timer: Timer?
    var configuration = 0, phase = 0, frame = 0
    var work: [Double] = [], times: [Double] = [], results: [[String: Any]] = []
    var origin = NSPoint.zero
    let configurations: [(CGFloat,CGFloat,Bool)] = [(960,720,true),(760,580,true),(960,720,false),(760,580,false)]
    let phases = ["mapping-down","mapping-up","preview-vertical","preview-horizontal"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard FileManager.default.fileExists(atPath: isolation.appending(path: "shield.ready").path) else { finish(error: "No input isolation"); return }
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true); try nextWindow() }
        catch { finish(error: error.localizedDescription) }
    }
    func nextWindow() throws {
        if configuration == configurations.count { finish(error: nil); return }
        let (width,height,dark) = configurations[configuration]
        let columns = (0..<2000).map { WorkspaceDataImportModel.SourceColumn(name: "column_\($0)_mapping", index: $0) }
        let targets = columns.map { WorkspaceDatabaseColumn(name: $0.name, type: "varchar(1024)", collation: nil, isNullable: true, key: "", defaultValue: nil, extra: "", comment: "") }
        let payload = String(repeating: "中文🙂 long value ", count: 32)
        let rows = (0..<200).map { index in WorkspaceDataImportModel.PreviewRow(id: index, cells: (0..<78).map { "\(index):\($0) " + payload }) }
        let root = HStack(spacing: 16) {
            WorkspaceDataImportMappingTable(sourceColumns: columns, targetColumns: targets, mapping: columns.map(\.name), onChange: { _,_ in }).frame(width: 300)
            Divider()
            WorkspaceDataImportPreviewTable(rows: rows, columns: Array(columns.prefix(78)))
        }.padding(20).environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:width,height:height),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "QueryCraft 导入滚动性能验证 · Esc 退出"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // All other pixels remain masked and HID input stays isolated. Keeping this
        // test window above the mask prevents occlusion from suppressing drawing.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())+2)
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window; self.host = host
        host.layoutSubtreeIfNeeded(); window.display()
        func tables(_ view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap(tables)
        }
        let tables = tables(host)
        mapping = tables.first(where: { $0.tableColumns.count == 2 })?.enclosingScrollView
        preview = tables.first(where: { $0.tableColumns.count == 78 })?.enclosingScrollView
        guard mapping != nil, preview != nil else { throw NSError(domain:"scroll",code:1,userInfo:[NSLocalizedDescriptionKey:"Native tables missing"]) }
        phase = 0; startPhase()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func startPhase() {
        frame = 0; work = []; times = []
        origin = (phase < 2 ? mapping : preview)?.contentView.bounds.origin ?? .zero
    }
    func tick() {
        guard FileManager.default.fileExists(atPath:isolation.appending(path:"shield.ready").path), let window, let target = phase < 2 ? mapping : preview else { finish(error:"Isolation ended"); return }
        let start = CACurrentMediaTime()
        autoreleasepool {
            let vertical: Int32 = phase == 0 ? -60 : phase == 1 ? 60 : phase == 2 ? -30 : 0
            let horizontal: Int32 = phase == 3 ? -60 : 0
            if let cg = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:vertical,wheel2:horizontal,wheel3:0) {
                cg.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
                if let event = NSEvent(cgEvent:cg) { target.scrollWheel(with:event) }
            }
            host?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        if frame >= 10 { work.append((CACurrentMediaTime()-start)*1000); times.append(start) }
        frame += 1
        if frame < 120 { return }
        let end = target.contentView.bounds.origin
        guard end != origin else { finish(error:"Scroll events did not move \(phases[phase])"); return }
        let intervals = zip(times.dropFirst(),times).map { ($0-$1)*1000 }
        let (width,height,dark) = configurations[configuration]
        results.append(["width":width,"height":height,"dark":dark,"phase":phases[phase],
            "frames":work.count,"fps":Double(max(0,times.count-1))/max(0.001,(times.last ?? 0)-(times.first ?? 0)),
            "p95WorkMs":percentile(work,0.95),"maxWorkMs":work.max() ?? 0,
            "p95FrameIntervalMs":percentile(intervals,0.95),"intervalsOver33ms":intervals.filter { $0>33.34 }.count])
        if let data = try? JSONSerialization.data(withJSONObject: ["results": results], options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: output.appending(path: "scroll-progress.json"))
        }
        phase += 1
        if phase < 4 { startPhase(); return }
        timer?.invalidate(); timer = nil
        let request = "\(window.windowNumber)\n\(output.appending(path:"scroll-\(Int(width))-\(dark ? "dark" : "light").png").path)"
        try? request.write(to:isolation.appending(path:"capture-request"),atomically:true,encoding:.utf8)
        // Give the supervising process time to capture the actual native window.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
            window.orderOut(nil); window.close(); self.window = nil; self.host = nil
            self.configuration += 1
            do { try self.nextWindow() } catch { self.finish(error:error.localizedDescription) }
        }
    }
    func percentile(_ values:[Double],_ percentile:Double)->Double {
        let sorted=values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count-1)*percentile))]
    }
    func finish(error:String?) {
        timer?.invalidate(); window?.orderOut(nil)
        var report:[String:Any] = ["results":results,"method":"Native scrollWheel event delivery and window drawing at a 60 Hz timer; 10 warm-up frames excluded per phase. Not a hardware trackpad/display-link FPS measurement."]
        if let error { report["error"] = error }
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:output.appending(path:"scroll.json")) }
        NSApplication.shared.terminate(nil)
    }
}
