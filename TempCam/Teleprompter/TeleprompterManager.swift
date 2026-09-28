import SwiftUI
import UIKit

/// In-memory teleprompter state. Nothing here is written to disk.
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
    var hudText: String?
    var showsHint = false
    var highlightedDirection: TeleprompterDirection?

    private(set) var contentHeight: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 1
    private var segmentStart = Date()
    private var segmentBase: CGFloat = 0
    private var gestureOriginSpeed = 1.0
    private var gestureOriginFont = 30.0
    private var lockedAxis: Axis?
    private var fontAnchorFraction: CGFloat?

    static let minimumSpeed = 0.3
    static let maximumSpeed = 2.6
    static let minimumFontSize = 20.0
    static let maximumFontSize = 48.0
    /// Points per second at 1×. A calm speaking pace at the default text size.
    static let basePointsPerSecond = 34.0

    var pointsPerSecond: Double { speed * Self.basePointsPerSecond }

    var speedLabel: String {
        String(format: "%.1f×", speed)
    }

    var hasScript: Bool {
        !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hudTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?

    func offset(at date: Date) -> CGFloat {
        let limit = contentHeight > 1 ? contentHeight : .greatestFiniteMagnitude
        guard isActive, !isPaused else { return min(segmentBase, limit) }
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
        showsHint = true
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled else { return }
            showsHint = false
        }
    }

    /// Drops the script. Called when a recording finishes, and from the sheet.
    func discard() {
        hintTask?.cancel()
        hudTask?.cancel()
        script = ""
        isActive = false
        isPaused = true
        segmentBase = 0
        scrollOffset = 0
        showsHint = false
        hudText = nil
        highlightedDirection = nil
        contentHeight = 0
    }

    func togglePause() {
        guard isActive else { return }
        showsHint = false
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
        showsHint = false
    }

    func pauseForBackground() {
        guard isActive, !isPaused else { return }
        segmentBase = offset(at: .now)
        isPaused = true
    }

    func setSpeed(from origin: Double, translation: CGFloat) {
        let frozen = offset(at: .now)
        let delta = -Double(translation) / 160
        speed = min(Self.maximumSpeed, max(Self.minimumSpeed, origin + delta))
        segmentBase = frozen
        segmentStart = .now
        revealHUD(speedLabel)
        showsHint = false
    }

    func setFontSize(from origin: Double, translation: CGFloat) {
        fontSize = min(Self.maximumFontSize, max(Self.minimumFontSize, origin + Double(translation) / 6))
        revealHUD("\(Int(fontSize.rounded()))")
        showsHint = false
    }

    func handleSwipe(translation: CGPoint, state: UIGestureRecognizer.State) {
        guard isActive else { return }
        switch state {
        case .began:
            gestureOriginSpeed = speed
            gestureOriginFont = fontSize
            lockedAxis = nil
            fontAnchorFraction = nil
            showsHint = false
        case .changed:
            let dx = translation.x
            let dy = translation.y
            if lockedAxis == nil {
                guard max(abs(dx), abs(dy)) > 14 else { return }
                lockedAxis = abs(dy) >= abs(dx) ? .vertical : .horizontal
                if lockedAxis == .horizontal {
                    fontAnchorFraction = contentHeight > 1 ? offset(at: .now) / contentHeight : 0
                }
            }
            if lockedAxis == .vertical {
                setSpeed(from: gestureOriginSpeed, translation: dy)
                highlightedDirection = dy < 0 ? .up : .down
            } else {
                setFontSize(from: gestureOriginFont, translation: dx)
                highlightedDirection = dx >= 0 ? .right : .left
            }
        default:
            highlightedDirection = nil
            lockedAxis = nil
        }
    }

    func nudgeSpeed(_ direction: AccessibilityAdjustmentDirection) {
        let frozen = offset(at: .now)
        let step = 0.1
        switch direction {
        case .increment:
            speed = min(Self.maximumSpeed, speed + step)
        case .decrement:
            speed = max(Self.minimumSpeed, speed - step)
        @unknown default:
            break
        }
        segmentBase = frozen
        segmentStart = .now
        revealHUD(speedLabel)
    }

    func pauseAtEnd() {
        guard isActive, !isPaused, contentHeight > 1 else { return }
        segmentBase = contentHeight
        scrollOffset = contentHeight
        isPaused = true
    }

    func updateMetrics(contentHeight: CGFloat, viewportHeight: CGFloat) {
        let heightChanged = abs(self.contentHeight - contentHeight) > 0.5
        if heightChanged {
            self.contentHeight = contentHeight
            if let fontAnchorFraction {
                let anchored = min(max(0, fontAnchorFraction * contentHeight), contentHeight)
                segmentBase = anchored
                segmentStart = .now
            }
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

    private func revealHUD(_ text: String) {
        hudText = text
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            hudText = nil
        }
    }
}

enum TeleprompterDirection: Equatable {
    case up, down, left, right
}
