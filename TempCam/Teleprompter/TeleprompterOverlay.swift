import SwiftUI
import UIKit

struct TeleprompterOverlay: View {
    var model: TeleprompterManager

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(model.backgroundOpacity))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            TeleprompterScrollingText(model: model)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .allowsHitTesting(false)

            readingGuide
        }
        .overlay(alignment: .top) {
            statusRow
                .padding(.top, 10)
        }
        .overlay(alignment: .bottomTrailing) {
            TeleprompterPad(model: model)
                .padding(8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Teleprompter")
        .accessibilityValue(model.isPaused ? "Paused" : "Scrolling")
        .accessibilityHint("Use the corner control to play or pause. Swipe up or down to change speed. Swipe left or right to change text size.")
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
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(height: 1)
                .padding(.horizontal, 28)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.38)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusRow: some View {
        if model.showsHint {
            Text("Swipe anywhere to adjust")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.35), in: Capsule())
                .allowsHitTesting(false)
        } else if model.isPaused {
            HStack(spacing: 8) {
                Text("Paused")
                    .font(.system(size: 13, weight: .semibold))
                Button("Reset") {
                    model.resetToStart()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CameraChrome.accent)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55), in: Capsule())
        }
    }
}

private struct TeleprompterScrollingText: View {
    var model: TeleprompterManager

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: model.isPaused || !model.isActive)) { timeline in
            TeleprompterCanvas(
                text: model.script,
                fontSize: CGFloat(model.fontSize),
                offset: model.offset(at: timeline.date)
            ) { contentHeight, viewportHeight in
                model.updateMetrics(contentHeight: contentHeight, viewportHeight: viewportHeight)
            } onReachedEnd: {
                model.pauseAtEnd()
            }
        }
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

struct TeleprompterPad: View {
    var model: TeleprompterManager

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))

            directionArrow("chevron.up", direction: .up, x: 0, y: -27)
            directionArrow("chevron.down", direction: .down, x: 0, y: 27)
            directionArrow("chevron.left", direction: .left, x: -27, y: 0)
            directionArrow("chevron.right", direction: .right, x: 27, y: 0)

            Button {
                Haptics.soft()
                model.togglePause()
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: model.isPaused ? 1 : 0)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.16), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isPaused ? "Play script" : "Pause script")
        }
        .frame(width: 88, height: 88)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.12), value: model.highlightedDirection)
        .animation(.easeOut(duration: 0.12), value: model.isPaused)
    }

    private func directionArrow(_ name: String, direction: TeleprompterDirection, x: CGFloat, y: CGFloat) -> some View {
        let active = model.highlightedDirection == direction
        return Image(systemName: name)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(active ? CameraChrome.accent : Color.white.opacity(0.78))
            .scaleEffect(active ? 1.18 : 1)
            .offset(x: x, y: y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
