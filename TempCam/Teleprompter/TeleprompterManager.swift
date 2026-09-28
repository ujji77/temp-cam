import SwiftUI
import UIKit

/// Which half of the screen a double tap landed on.
enum TeleprompterSide: Equatable {
    case leading, trailing
}

/// Feedback shown after a double tap changes speed. `id` changes on every tap so
/// repeated taps at the same speed (e.g. at the limit) still animate.
struct SpeedPulse: Equatable {
    var side: TeleprompterSide
    var speed: Double
    var hitLimit: Bool
    var id: Int
}

/// In-memory teleprompter state. The script is never written to disk; only the
/// number of times the gesture hints have been shown is kept in `UserDefaults`.
@MainActor
@Observable
final class TeleprompterManager {
    var script = ""
    var isActive = false
    var isPaused = true
    var speed = 1.0
    var fontSize = 30.0
    var backgroundOpacity = 0.4
    var scrollOffset: CGFloat = 0
    var showsHint = false
    private(set) var isScrubbing = false
    private(set) var speedPulse: SpeedPulse?

    private(set) var contentHeight: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 1
    private var segmentStart = Date()
    private var segmentBase: CGFloat = 0
    private var scrubOrigin: CGFloat = 0
    private var pulseCount = 0

    static let minimumSpeed = 0.2
    static let maximumSpeed = 3.0
    /// How much one double tap changes speed.
    static let speedStep = 0.2
    static let minimumFontSize = 20.0
    static let maximumFontSize = 48.0
    /// Points per second at 1×. A calm speaking pace at the default text size.
    static let basePointsPerSecond = 34.0
    /// Gesture hints appear automatically for the first few scripts, then only on request.
    static let automaticHintLimit = 3
    static let hintCountKey = "teleprompter.hintsShown"

    var pointsPerSecond: Double { speed * Self.basePointsPerSecond }

    var speedLabel: String {
        String(format: "%.1f×", speed)
    }

    var hasScript: Bool {
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 0...1 position through the script, for the scroll indicator.
    func progress(at date: Date) -> CGFloat {
        guard contentHeight > 1 else { return 0 }
        return min(max(offset(at: date) / contentHeight, 0), 1)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pulseTask: Task<Void, Never>?
    @ObservationIgnored private var hintTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func offset(at date: Date) -> CGFloat {
        let limit = contentHeight > 1 ? contentHeight : .greatestFiniteMagnitude
        guard isActive, !isPaused, !isScrubbing else { return min(segmentBase, limit) }
        let elapsed = date.timeIntervalSince(segmentStart)
        let value = segmentBase + CGFloat(max(0, elapsed) * pointsPerSecond)
        return min(max(0, value), limit)
    }

    func start() {
        guard hasScript else { return }
        segmentBase = 0
        segmentStart = .now
        scrollOffset = 0
        isActive = true
        isPaused = false
        let shown = defaults.integer(forKey: Self.hintCountKey)
        if shown < Self.automaticHintLimit {
            defaults.set(shown + 1, forKey: Self.hintCountKey)
            revealHints()
        }
    }

    /// Shows the gesture hints on demand (tapping the speed readout).
    func revealHints() {
        guard isActive else { return }
        showsHint = true
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showsHint = false
        }
    }

    func dismissHints() {
        hintTask?.cancel()
        showsHint = false
    }

    /// Drops the script. Called when a recording finishes, and from the sheet.
    func discard() {
        hintTask?.cancel()
        pulseTask?.cancel()
        script = ""
        isActive = false
        isPaused = true
        isScrubbing = false
        segmentBase = 0
        scrollOffset = 0
        showsHint = false
        speedPulse = nil
        contentHeight = 0
    }

    func togglePause() {
        guard isActive else { return }
        dismissHints()
        if isPaused {
            if contentHeight > 1, segmentBase >= contentHeight - 1 {
                resetToStart()
                return
            }
            segmentStart = .now
            isPaused = false
        } else {
            segmentBase = offset(at: .now)
            isPaused = true
        }
    }

    func resetToStart() {
        guard isActive else { return }
        segmentBase = 0
        segmentStart = .now
        scrollOffset = 0
        isPaused = false
        dismissHints()
    }

    func pauseForBackground() {
        guard isActive, !isPaused else { return }
        segmentBase = offset(at: .now)
        isPaused = true
    }

    /// Vertical swipes move the script like a scroll view: swipe up to read ahead,
    /// down to go back. Auto-scroll holds while the finger is down and resumes
    /// from the new position on release.
    func handleSwipe(translation: CGPoint, state: UIGestureRecognizer.State) {
        guard isActive else { return }
        switch state {
        case .began:
            scrubOrigin = offset(at: .now)
            segmentBase = scrubOrigin
            isScrubbing = true
            dismissHints()
        case .changed:
            guard isScrubbing else { return }
            scrub(to: scrubOrigin - translation.y)
        default:
            guard isScrubbing else { return }
            isScrubbing = false
            segmentStart = .now
        }
    }

    private func scrub(to value: CGFloat) {
        let limit = contentHeight > 1 ? contentHeight : 0
        segmentBase = min(max(0, value), limit)
        scrollOffset = segmentBase
    }

    /// Double tap on the trailing half speeds up, leading half slows down.
    func stepSpeed(from side: TeleprompterSide) {
        guard isActive else { return }
        let delta = side == .trailing ? Self.speedStep : -Self.speedStep
        let changed = changeSpeed(by: delta)
        dismissHints()
        pulseCount += 1
        speedPulse = SpeedPulse(side: side, speed: speed, hitLimit: !changed, id: pulseCount)
        pulseTask?.cancel()
        pulseTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            speedPulse = nil
        }
    }

    func nudgeSpeed(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment:
            changeSpeed(by: Self.speedStep)
        case .decrement:
            changeSpeed(by: -Self.speedStep)
        @unknown default:
            break
        }
    }

    /// Returns false when already at the limit in that direction.
    @discardableResult
    private func changeSpeed(by delta: Double) -> Bool {
        let target = ((speed + delta) * 10).rounded() / 10
        let clamped = min(Self.maximumSpeed, max(Self.minimumSpeed, target))
        guard abs(clamped - speed) > 0.001 else { return false }
        let frozen = offset(at: .now)
        speed = clamped
        segmentBase = frozen
        segmentStart = .now
        return true
    }

    func pauseAtEnd() {
        guard isActive, !isPaused, !isScrubbing, contentHeight > 1 else { return }
        segmentBase = contentHeight
        scrollOffset = contentHeight
        isPaused = true
    }

    func updateMetrics(contentHeight: CGFloat, viewportHeight: CGFloat) {
        if abs(self.contentHeight - contentHeight) > 0.5 {
            self.contentHeight = contentHeight
        }
        if viewportHeight > 1, abs(self.viewportHeight - viewportHeight) > 0.5 {
            self.viewportHeight = viewportHeight
        }
    }

    func pasteFromClipboard() -> Bool {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return false
        }
        script = text
        return true
    }
}
