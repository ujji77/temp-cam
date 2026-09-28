import SwiftUI
import UIKit

struct TeleprompterOverlay: View {
    var model: TeleprompterManager

    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        ZStack {
            TeleprompterScrollingText(model: model)
                .clipShape(shape)
            readingGuide
        }
        .background {
            shape
                .fill(.clear)
                .glassEffect(.regular.tint(.black.opacity(model.backgroundOpacity)), in: shape)
        }
        // Taps on the script fall through to the camera preview, which owns the
        // double-tap speed gesture. Only the controls below are interactive.
        .allowsHitTesting(false)
        .overlay(alignment: .top) {
            statusRow
                .padding(.top, 10)
        }
        .overlay(alignment: .bottomTrailing) {
            TeleprompterControl(model: model)
                .padding(10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Teleprompter")
        .accessibilityValue(model.isPaused ? "Paused, \(model.speedLabel)" : "Scrolling, \(model.speedLabel)")
        .accessibilityHint("Swipe up or down to scroll. Double-tap the right side of the screen to speed up, the left side to slow down.")
        .accessibilityAction(.default) {
            model.togglePause()
        }
        .accessibilityAction(named: "Reset") {
            model.resetToStart()
        }
        .accessibilityAdjustableAction { direction in
            model.nudgeSpeed(direction)
        }
    }

    private var readingGuide: some View {
        GeometryReader { geo in
            Capsule()
                .fill(CameraChrome.accent.opacity(0.55))
                .frame(width: 3, height: 22)
                .position(x: 10, y: geo.size.height * 0.38)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusRow: some View {
        if model.isPaused, !model.isScrubbing {
            HStack(spacing: 10) {
                Text("Paused")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Button {
                    Haptics.tap()
                    model.resetToStart()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CameraChrome.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

private struct TeleprompterScrollingText: View {
    var model: TeleprompterManager

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: model.isPaused || model.isScrubbing || !model.isActive)) { timeline in
            TeleprompterCanvas(
                text: model.script,
                fontSize: CGFloat(model.fontSize),
                offset: model.offset(at: timeline.date)
            ) { contentHeight, viewportHeight in
                model.updateMetrics(contentHeight: contentHeight, viewportHeight: viewportHeight)
            } onReachedEnd: {
                model.pauseAtEnd()
            }
            .overlay(alignment: .trailing) {
                ScrollPositionIndicator(progress: model.progress(at: timeline.date))
                    .padding(.vertical, 18)
                    .padding(.trailing, 7)
                    .opacity(model.isScrubbing ? 1 : 0)
                    .animation(.easeOut(duration: model.isScrubbing ? 0.12 : 0.6), value: model.isScrubbing)
            }
        }
    }
}

/// Thin track on the teleprompter's edge that shows where you are while swiping.
private struct ScrollPositionIndicator: View {
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            let thumb: CGFloat = 26
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(width: 3)
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: thumb)
                    .offset(y: (geo.size.height - thumb) * progress)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 3)
    }
}

private struct TeleprompterCanvas: UIViewRepresentable {
    var text: String
    var fontSize: CGFloat
    var offset: CGFloat
    var onMetrics: (CGFloat, CGFloat) -> Void
    var onReachedEnd: () -> Void

    func makeUIView(context: Context) -> TeleprompterCanvasView {
        let view = TeleprompterCanvasView()
        view.isUserInteractionEnabled = false
        view.onMetrics = onMetrics
        view.onReachedEnd = onReachedEnd
        return view
    }

    func updateUIView(_ view: TeleprompterCanvasView, context: Context) {
        view.onMetrics = onMetrics
        view.onReachedEnd = onReachedEnd
        view.render(text: text, fontSize: fontSize, offset: offset)
    }
}

/// Compact glass control: tap the speed to see gesture hints, tap the button to play or pause.
struct TeleprompterControl: View {
    var model: TeleprompterManager

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    Haptics.tap()
                    model.showsHint ? model.dismissHints() : model.revealHints()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(model.speedLabel)
                            .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: model.speed))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.black.opacity(0.2)).interactive(), in: Capsule())
                .accessibilityLabel("Speed \(model.speedLabel)")
                .accessibilityHint("Shows gesture tips")

                Button {
                    Haptics.soft()
                    model.togglePause()
                } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.black.opacity(0.2)).interactive(), in: Circle())
                .accessibilityLabel(model.isPaused ? "Play script" : "Pause script")
            }
        }
        .animation(.snappy(duration: 0.2), value: model.speed)
        .animation(.snappy(duration: 0.2), value: model.isPaused)
    }
}

struct ScreenSwipeCatcher: UIViewRepresentable {
    var isEnabled: Bool
    var onPan: (UIPanGestureRecognizer) -> Void

    func makeUIView(context: Context) -> ScreenSwipeView {
        let view = ScreenSwipeView()
        view.isEnabled = isEnabled
        view.onPan = onPan
        return view
    }

    func updateUIView(_ view: ScreenSwipeView, context: Context) {
        view.isEnabled = isEnabled
        view.onPan = onPan
    }
}

final class ScreenSwipeView: UIView, UIGestureRecognizerDelegate {
    var isEnabled = false
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    private var pan: UIPanGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let pan {
            pan.view?.removeGestureRecognizer(pan)
            self.pan = nil
        }
        guard let window else { return }
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
        pan = recognizer
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard isEnabled else { return }
        onPan?(recognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

final class TeleprompterCanvasView: UIView {
    var onMetrics: ((CGFloat, CGFloat) -> Void)?
    var onReachedEnd: (() -> Void)?
    private var didReportEnd = false

    private let label = UILabel()
    private let fade = CAGradientLayer()
    private var renderedText = ""
    private var renderedFontSize: CGFloat = 0
    private var renderedWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        label.numberOfLines = 0
        label.backgroundColor = .clear
        addSubview(label)
        fade.colors = [
            UIColor.clear.cgColor,
            UIColor.white.cgColor,
            UIColor.white.cgColor,
            UIColor.clear.cgColor
        ]
        fade.locations = [0, 0.12, 0.78, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fade.frame = bounds
        render(text: renderedText, fontSize: renderedFontSize == 0 ? 30 : renderedFontSize, offset: currentOffset)
    }

    private var currentOffset: CGFloat = 0

    func render(text: String, fontSize: CGFloat, offset: CGFloat) {
        currentOffset = offset
        let width = max(0, bounds.width - 36)
        let needsLayout = text != renderedText || abs(fontSize - renderedFontSize) > 0.1 || abs(width - renderedWidth) > 0.5
        if needsLayout, width > 1 {
            label.attributedText = Self.attributed(text, fontSize: fontSize)
            let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            measuredHeight = ceil(size.height)
            renderedText = text
            renderedFontSize = fontSize
            renderedWidth = width
            didReportEnd = false
            let height = measuredHeight
            let viewport = bounds.height
            DispatchQueue.main.async { [weak self] in
                self?.onMetrics?(height, viewport)
            }
        }

        if measuredHeight > 1, offset >= measuredHeight - 0.5, !didReportEnd {
            didReportEnd = true
            DispatchQueue.main.async { [weak self] in
                self?.onReachedEnd?()
            }
        }

        guard width > 1 else { return }
        if offset < measuredHeight - 1 {
            didReportEnd = false
        }
        let readingLine = bounds.height * 0.38
        label.frame = CGRect(
            x: 18,
            y: readingLine - offset,
            width: width,
            height: max(measuredHeight, 1)
        )
    }

    private static func attributed(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = fontSize * 0.22
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.8)
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.shadowBlurRadius = 3
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: style,
            .shadow: shadow,
            .kern: 0.15
        ])
    }
}
