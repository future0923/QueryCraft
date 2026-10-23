import CoreGraphics
import Testing
@testable import QueryCraftMobileProof

struct MobileGridAxisLockTests {
    @Test func horizontalGestureCannotDriftVerticallyEvenAfterDirectionChanges() {
        var lock = MobileGridAxisLock()
        lock.begin(at: CGPoint(x: 80, y: 120), translation: CGPoint(x: 20, y: 8))
        #expect(lock.constrain(CGPoint(x: 200, y: 150)) == CGPoint(x: 200, y: 120))
        #expect(lock.constrain(CGPoint(x: 240, y: 500), translation: CGPoint(x: 21, y: 90)) == CGPoint(x: 240, y: 120))
        #expect(lock.constrain(CGPoint(x: 600, y: 900), velocity: CGPoint(x: 1, y: 4)) == CGPoint(x: 600, y: 120))
    }
    @Test func verticalGestureCannotDriftHorizontally() {
        var lock = MobileGridAxisLock()
        lock.begin(at: CGPoint(x: 80, y: 120), translation: CGPoint(x: 6, y: -20))
        #expect(lock.constrain(CGPoint(x: 140, y: 400)) == CGPoint(x: 80, y: 400))
        #expect(lock.constrain(CGPoint(x: 600, y: 900), velocity: CGPoint(x: 4, y: 1)) == CGPoint(x: 80, y: 900))
    }
    @Test func tinyMovementWaitsAndExactDiagonalStillChoosesOnlyOneAxis() {
        var lock = MobileGridAxisLock()
        lock.begin(at: CGPoint(x: 80, y: 120))
        #expect(lock.constrain(CGPoint(x: 81, y: 121), translation: CGPoint(x: 1, y: 1)) == CGPoint(x: 80, y: 120))
        #expect(lock.constrain(CGPoint(x: 100, y: 140), translation: CGPoint(x: 10, y: 10)) == CGPoint(x: 100, y: 120))
    }
    @Test func nextGestureCanUseOtherAxisAndEndingAllowsProgrammaticRestore() {
        var lock = MobileGridAxisLock()
        lock.begin(at: .zero, velocity: CGPoint(x: 300, y: 20))
        #expect(lock.constrain(CGPoint(x: 100, y: 10)) == CGPoint(x: 100, y: 0))
        lock.end()
        #expect(lock.constrain(CGPoint(x: 100, y: 200)) == CGPoint(x: 100, y: 200))
        lock.begin(at: CGPoint(x: 100, y: 200), velocity: CGPoint(x: 20, y: -300))
        #expect(lock.constrain(CGPoint(x: 150, y: 50)) == CGPoint(x: 100, y: 50))
    }
}
