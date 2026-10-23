import XCTest
import SwiftUI
import UIKit
@testable import QueryCraftMobileProof

@MainActor final class MobileDataExportPresentationTests: XCTestCase {
    func testNativeSavePickerKeepsPreparedFileAndRawSnapshotAlive() async throws {
        let model = MobileDataExportModel(snapshot: .init(data: .init(columns: ["id"], rows: [["318987599031067570"]]),
            name: "result", scopeDescription: "当前查询结果"))
        model.format = .csv
        // Standalone hosting controllers do not receive App/Scene's environment.
        let host = UIHostingController(rootView: MobileDataExportView(model: model).environment(\.scenePhase, .active))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { model.cancel(); window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let operation = try XCTUnwrap(model.prepare()); await operation.value
        let file = try XCTUnwrap(model.file)
        let deadline = ContinuousClock.now + .seconds(5)
        while host.presentedViewController == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let picker = try XCTUnwrap(host.presentedViewController)
        XCTAssertTrue(containsDocumentPicker(picker), "Use the native Files picker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), "Presenting Files must not clean up its source")
        XCTAssertTrue(try String(contentsOf: file.url, encoding: .utf8).contains("318987599031067570"))
        XCTAssertEqual(model.file?.id, file.id)
        await picker.dismiss(animated: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), "Canceling Files keeps the prepared file for retry")
    }

    private func containsDocumentPicker(_ controller: UIViewController) -> Bool {
        controller is UIDocumentPickerViewController || controller.children.contains(where: containsDocumentPicker)
    }
}
