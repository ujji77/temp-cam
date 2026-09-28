import XCTest
@testable import TempCam

@MainActor
final class TeleprompterManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "TeleprompterManagerTests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// An active teleprompter with a measured script, paused so offsets are deterministic.
    private func makeActive(contentHeight: CGFloat = 1000, paused: Bool = true) -> TeleprompterManager {
        let model = TeleprompterManager(defaults: defaults)
        model.script = "Hello world"
        model.start()
        model.updateMetrics(contentHeight: contentHeight, viewportHeight: 250)
        if paused { model.togglePause() }
        return model
    }

    // MARK: Swipe to scroll

    func testSwipeUpScrollsForward() {
        let model = makeActive()

        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: -120), state: .changed)

        XCTAssertEqual(model.offset(at: .now), 120, accuracy: 0.5)
        XCTAssertTrue(model.isScrubbing)
    }

    func testSwipeDownScrollsBack() {
        let model = makeActive()
        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: -300), state: .changed)
        model.handleSwipe(translation: CGPoint(x: 0, y: -300), state: .ended)

        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: 100), state: .changed)

        XCTAssertEqual(model.offset(at: .now), 200, accuracy: 0.5)
    }

    func testScrollClampsToScriptBounds() {
        let model = makeActive(contentHeight: 500)

        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: 400), state: .changed)
        XCTAssertEqual(model.offset(at: .now), 0)

        model.handleSwipe(translation: CGPoint(x: 0, y: -5000), state: .changed)
        XCTAssertEqual(model.offset(at: .now), 500)
    }

    func testAutoScrollHoldsWhileFingerIsDown() {
        let model = makeActive(paused: false)

        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: -50), state: .changed)
        let held = model.offset(at: .now)

        XCTAssertEqual(model.offset(at: .now.addingTimeInterval(5)), held, "Script must not drift during a swipe")
        XCTAssertFalse(model.isPaused, "Swiping shouldn't flip the play/pause state")
    }

    func testAutoScrollResumesFromReleasePoint() {
        let model = makeActive(paused: false)
        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: -200), state: .changed)
        let released = model.offset(at: .now)

        model.handleSwipe(translation: CGPoint(x: 0, y: -200), state: .ended)

        XCTAssertFalse(model.isScrubbing)
        let later = model.offset(at: .now.addingTimeInterval(1))
        XCTAssertEqual(later, released + CGFloat(model.pointsPerSecond), accuracy: 2)
    }

    func testPausedScriptStaysPausedAfterSwipe() {
        let model = makeActive()
        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: -80), state: .changed)
        model.handleSwipe(translation: CGPoint(x: 0, y: -80), state: .ended)

        XCTAssertTrue(model.isPaused)
        XCTAssertEqual(model.offset(at: .now.addingTimeInterval(3)), 80, accuracy: 0.5)
    }

    func testHorizontalSwipeNoLongerChangesTextSize() {
        let model = makeActive()
        let size = model.fontSize

        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 200, y: 0), state: .changed)
        model.handleSwipe(translation: CGPoint(x: 200, y: 0), state: .ended)

        XCTAssertEqual(model.fontSize, size)
        XCTAssertEqual(model.offset(at: .now), 0, accuracy: 0.5)
    }

    func testSwipeIgnoredWhenInactive() {
        let model = TeleprompterManager(defaults: defaults)
        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: -100), state: .changed)

        XCTAssertFalse(model.isScrubbing)
        XCTAssertEqual(model.offset(at: .now), 0)
    }

    func testReachingEndWhileScrubbingDoesNotPause() {
        let model = makeActive(contentHeight: 300, paused: false)
        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: -1000), state: .changed)

        model.pauseAtEnd()

        XCTAssertFalse(model.isPaused)
    }

    // MARK: Double-tap speed

    func testDoubleTapRightSpeedsUp() {
        let model = makeActive()

        model.stepSpeed(from: .trailing)

        XCTAssertEqual(model.speed, 1.2, accuracy: 0.001)
        XCTAssertEqual(model.speedPulse?.side, .trailing)
        XCTAssertEqual(model.speedPulse?.hitLimit, false)
    }

    func testDoubleTapLeftSlowsDown() {
        let model = makeActive()

        model.stepSpeed(from: .leading)

        XCTAssertEqual(model.speed, 0.8, accuracy: 0.001)
        XCTAssertEqual(model.speedPulse?.side, .leading)
    }

    func testSpeedClampsAtMaximumAndReportsLimit() {
        let model = makeActive()
        for _ in 0..<30 { model.stepSpeed(from: .trailing) }

        XCTAssertEqual(model.speed, TeleprompterManager.maximumSpeed, accuracy: 0.001)
        XCTAssertEqual(model.speedPulse?.hitLimit, true)
    }

    func testSpeedClampsAtMinimum() {
        let model = makeActive()
        for _ in 0..<30 { model.stepSpeed(from: .leading) }

        XCTAssertEqual(model.speed, TeleprompterManager.minimumSpeed, accuracy: 0.001)
        XCTAssertEqual(model.speedPulse?.hitLimit, true)
    }

    func testRepeatedStepsDoNotAccumulateFloatingPointError() {
        let model = makeActive()
        for _ in 0..<5 { model.stepSpeed(from: .trailing) }
        for _ in 0..<5 { model.stepSpeed(from: .leading) }

        XCTAssertEqual(model.speed, 1.0)
    }

    func testEachTapProducesANewPulse() {
        let model = makeActive()
        model.stepSpeed(from: .trailing)
        let first = model.speedPulse?.id

        model.stepSpeed(from: .trailing)

        XCTAssertNotEqual(model.speedPulse?.id, first)
    }

    func testSpeedChangeKeepsScriptPosition() {
        let model = makeActive(paused: false)
        let before = model.offset(at: .now)

        model.stepSpeed(from: .trailing)

        XCTAssertEqual(model.offset(at: .now), before, accuracy: 2, "Changing speed must not make the script jump")
    }

    func testSpeedPulseClearsAfterDelay() async throws {
        let model = makeActive()
        model.stepSpeed(from: .trailing)

        try await Task.sleep(for: .milliseconds(1100))

        XCTAssertNil(model.speedPulse)
    }

    func testDoubleTapIgnoredWhenInactive() {
        let model = TeleprompterManager(defaults: defaults)
        model.stepSpeed(from: .trailing)

        XCTAssertEqual(model.speed, 1.0)
        XCTAssertNil(model.speedPulse)
    }

    func testAccessibilityAdjustUsesSameStep() {
        let model = makeActive()
        model.nudgeSpeed(.increment)
        XCTAssertEqual(model.speed, 1.2, accuracy: 0.001)
        model.nudgeSpeed(.decrement)
        model.nudgeSpeed(.decrement)
        XCTAssertEqual(model.speed, 0.8, accuracy: 0.001)
    }

    // MARK: Hints

    func testHintsShowAutomaticallyForFirstFewScripts() {
        for _ in 0..<TeleprompterManager.automaticHintLimit {
            let model = TeleprompterManager(defaults: defaults)
            model.script = "Hi"
            model.start()
            XCTAssertTrue(model.showsHint)
        }
        let model = TeleprompterManager(defaults: defaults)
        model.script = "Hi"
        model.start()
        XCTAssertFalse(model.showsHint)
    }

    func testHintsCanBeShownOnDemandAndDismissed() {
        defaults.set(TeleprompterManager.automaticHintLimit, forKey: TeleprompterManager.hintCountKey)
        let model = makeActive()
        XCTAssertFalse(model.showsHint)

        model.revealHints()
        XCTAssertTrue(model.showsHint)

        model.dismissHints()
        XCTAssertFalse(model.showsHint)
    }

    func testGesturesDismissHints() {
        let model = makeActive()
        model.revealHints()
        model.stepSpeed(from: .trailing)
        XCTAssertFalse(model.showsHint)

        model.revealHints()
        model.handleSwipe(translation: .zero, state: .began)
        XCTAssertFalse(model.showsHint)
    }

    func testDiscardResetsGestureState() {
        let model = makeActive()
        model.stepSpeed(from: .trailing)
        model.handleSwipe(translation: .zero, state: .began)

        model.discard()

        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.isScrubbing)
        XCTAssertNil(model.speedPulse)
        XCTAssertFalse(model.showsHint)
    }

    func testProgressTracksOffset() {
        let model = makeActive(contentHeight: 400)
        model.handleSwipe(translation: .zero, state: .began)
        model.handleSwipe(translation: CGPoint(x: 0, y: -100), state: .changed)

        XCTAssertEqual(model.progress(at: .now), 0.25, accuracy: 0.01)
    }
}
