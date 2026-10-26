import XCTest
import SwiftUI
import UIKit
import Observation
@testable import QueryCraftMobileProof

@MainActor final class MobileSwitchPresentationTests: XCTestCase {
    func testNativeSwitchUsesGreenWithoutChangingButtonToggles() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let values = SwitchValues()
        let host = UIHostingController(rootView: SwitchHarness(values: values).mobileAppearance())
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
            let controls = descendants(host.view).compactMap { $0 as? UISwitch }
            XCTAssertEqual(controls.count, 2, "The explicitly styled button toggle must remain a button")
            let enabled = try XCTUnwrap(controls.first { $0.isOn }), disabled = try XCTUnwrap(controls.first { !$0.isOn })
            let actual = try XCTUnwrap(enabled.onTintColor?.resolvedColor(with: enabled.traitCollection))
            let expected = UIColor.systemGreen.resolvedColor(with: enabled.traitCollection)
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
            XCTAssertTrue(actual.getRed(&ar, green: &ag, blue: &ab, alpha: &aa))
            XCTAssertTrue(expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea))
            for (a, e) in zip([ar, ag, ab, aa], [er, eg, eb, ea]) { XCTAssertEqual(a, e, accuracy: 0.00001) }
            XCTAssertEqual(enabled.bounds.size, disabled.bounds.size)
            let frame = enabled.bounds.size
            disabled.setOn(true, animated: false); disabled.sendActions(for: .valueChanged)
            XCTAssertTrue(values.disabled); XCTAssertEqual(disabled.bounds.size, frame)
            disabled.setOn(false, animated: false); disabled.sendActions(for: .valueChanged)
            XCTAssertFalse(values.disabled)
            let a = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) })
            a.name = "native-green-switch-\(style.rawValue)"; a.lifetime = .keepAlways; add(a)
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor @Observable private final class SwitchValues { var enabled = true; var disabled = false; var button = false }
private struct SwitchHarness: View {
    @Bindable var values: SwitchValues
    var body: some View {
        Form {
            Toggle("开启", isOn: $values.enabled)
            Toggle("关闭", isOn: $values.disabled)
            Toggle("JSON", isOn: $values.button).toggleStyle(.button)
        }.mobileCanvas()
    }
}
