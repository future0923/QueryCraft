import Foundation
import Testing

struct MobileOrientationTests {
    @Test func phoneSupportsPortraitAndBothLandscapeOrientations() {
        let orientations = Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String] ?? []
        #expect(orientations.contains("UIInterfaceOrientationPortrait"))
        #expect(orientations.contains("UIInterfaceOrientationLandscapeLeft"))
        #expect(orientations.contains("UIInterfaceOrientationLandscapeRight"))
    }
}
