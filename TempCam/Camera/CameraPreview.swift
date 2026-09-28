import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var configurationGeneration: Int
    var onFocus: (CGPoint) -> Void
    var onPinch: (_ scale: CGFloat, _ state: UIGestureRecognizer.State) -> Void
    /// When set, double taps report which half of the screen was hit. Single-tap
    /// focus then waits for the double tap to fail, so only enable it when needed.
    var onDoubleTap: ((_ isTrailingHalf: Bool) -> Void)?
    var onPreviewLayer: (AVCaptureVideoPreviewLayer) -> Void

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        view.onPinch = onPinch
        view.onDoubleTap = onDoubleTap
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        view.onFocus = onFocus
        view.onPinch = onPinch
        view.onDoubleTap = onDoubleTap
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        if context.coordinator.appliedGeneration != configurationGeneration || !context.coordinator.didAttachLayer {
            context.coordinator.appliedGeneration = configurationGeneration
            context.coordinator.didAttachLayer = true
            onPreviewLayer(view.previewLayer)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var appliedGeneration = -1
        var didAttachLayer = false
    }
}

final class CameraPreviewView: UIView, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onFocus: ((CGPoint) -> Void)?
    var onPinch: ((_ scale: CGFloat, _ state: UIGestureRecognizer.State) -> Void)?
    var onDoubleTap: ((_ isTrailingHalf: Bool) -> Void)? {
        didSet { doubleTap.isEnabled = onDoubleTap != nil }
    }

    private let reticle = UIView()
    private let doubleTap = UITapGestureRecognizer()
    private let tap = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true

        doubleTap.addTarget(self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.isEnabled = false
        addGestureRecognizer(doubleTap)

        tap.addTarget(self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        reticle.isUserInteractionEnabled = false
        reticle.layer.borderColor = UIColor(red: 1, green: 0.82, blue: 0, alpha: 0.95).cgColor
        reticle.layer.borderWidth = 1.5
        reticle.layer.cornerRadius = 2
        reticle.alpha = 0
        addSubview(reticle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        onFocus?(devicePoint)
        showReticle(at: point)
    }

    /// Focus waits to see whether a tap becomes a double tap, but only while double
    /// taps mean something. Otherwise focus stays instant.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === tap && otherGestureRecognizer === doubleTap && doubleTap.isEnabled
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        onDoubleTap?(point.x >= bounds.midX)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        onPinch?(recognizer.scale, recognizer.state)
    }

    private func showReticle(at point: CGPoint) {
        let side: CGFloat = 74
        reticle.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        reticle.center = point
        reticle.alpha = 1
        reticle.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.reticle.transform = .identity
        }
        UIView.animate(withDuration: 0.22, delay: 0.65, options: [.curveEaseIn, .allowUserInteraction]) {
            self.reticle.alpha = 0
        }
    }
}
