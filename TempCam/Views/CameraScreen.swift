import SwiftUI
import UIKit

enum CameraChrome {
    static let accent = Color(red: 1, green: 0.82, blue: 0)
    static let record = Color(red: 1, green: 0.23, blue: 0.19)
}

struct CameraScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = CameraManager()
    @State private var teleprompter = TeleprompterManager()
    @State private var showSettings = false
    @State private var flipTurns = 0.0

    var body: some View {
        GeometryReader { geo in
            let scriptHeight = min(252, max(200, geo.size.height * 0.29))
            ZStack {
                Color.black
                ScreenSwipeCatcher(isEnabled: teleprompter.isActive && !showSettings) { recognizer in
                    let translation = recognizer.translation(in: recognizer.view)
                    teleprompter.handleSwipe(translation: translation, state: recognizer.state)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                CameraPreview(
                    session: camera.session,
                    configurationGeneration: camera.configurationGeneration,
                    onFocus: { camera.focus(at: $0) },
                    onPinch: { camera.handlePinch(scale: $0, state: $1) },
                    onPreviewLayer: { camera.attachPreviewLayer($0) }
                )
                .ignoresSafeArea()

                if camera.authorization == .denied || camera.authorization == .restricted {
                    permissionView(canOpenSettings: true, message: "TempCam needs the camera and microphone to record. Scripts stay in memory only until you close the app.")
                } else if let unavailable = camera.unavailableMessage {
                    permissionView(canOpenSettings: false, message: unavailable)
                } else {
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.38)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 210)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    chrome(scriptHeight: scriptHeight)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            TeleprompterSettingsSheet(model: teleprompter)
        }
        .task {
            camera.onClipFinished = {
                teleprompter.discard()
            }
            await camera.prepare()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.setInterfaceActive(true)
            case .background:
                teleprompter.pauseForBackground()
                camera.setInterfaceActive(false)
            default:
                break
            }
        }
    }

    private func chrome(scriptHeight: CGFloat) -> some View {
        VStack(spacing: 12) {
            topBar
            if let notice = camera.notice {
                noticeBanner(notice)
                    .transition(.opacity)
            }
            if teleprompter.isActive {
                TeleprompterOverlay(model: teleprompter)
                    .frame(height: scriptHeight)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            zoomBar
                .opacity(camera.isRecording ? 0 : 1)
                .allowsHitTesting(!camera.isRecording)
            recordBar
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            if let hudText = teleprompter.hudText {
                Text(hudText)
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 148)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: teleprompter.hudText)
        .animation(.easeInOut(duration: 0.22), value: teleprompter.isActive)
        .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
        .animation(.easeInOut(duration: 0.2), value: camera.notice)
    }

    private var topBar: some View {
        ZStack {
            RecordingTimer(camera: camera)
            HStack {
                torchButton
                    .opacity(camera.isRecording ? 0 : 1)
                    .allowsHitTesting(!camera.isRecording)
                Spacer()
                teleprompterButton
            }
        }
        .padding(.horizontal, 18)
    }

    private var torchButton: some View {
        Button {
            Haptics.tap()
            camera.toggleTorch()
        } label: {
            Image(systemName: camera.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(camera.isTorchOn ? CameraChrome.accent : .white)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(camera.isTorchAvailable ? 1 : 0)
        .allowsHitTesting(camera.isTorchAvailable)
        .accessibilityLabel(camera.isTorchOn ? "Turn torch off" : "Turn torch on")
    }

    private var teleprompterButton: some View {
        Button {
            Haptics.tap()
            showSettings = true
        } label: {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(teleprompter.isActive ? CameraChrome.accent : .white)
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Teleprompter")
    }

    private var zoomBar: some View {
        HStack(spacing: 10) {
            let selectedID = selectedStopID(stops: camera.zoomStops, zoom: camera.displayZoom)
            ForEach(camera.zoomStops) { stop in
                let selected = stop.id == selectedID
                Button {
                    Haptics.tap()
                    camera.selectZoom(stop)
                } label: {
                    Text(zoomTitle(stop: stop, selected: selected, precise: camera.displayZoom))
                        .font(.system(size: selected ? 13 : 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(selected ? CameraChrome.accent : .white)
                        .frame(width: selected ? 42 : 34, height: selected ? 42 : 34)
                        .background(Color.black.opacity(0.42), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(formatZoom(stop.displayZoom)) times zoom")
            }
        }
        .frame(height: 44)
        .opacity(camera.zoomStops.count > 1 ? 1 : 0)
        .allowsHitTesting(camera.zoomStops.count > 1)
    }

    private var recordBar: some View {
        HStack {
            Color.clear.frame(width: 52, height: 52)
            Spacer()
            recordButton
            Spacer()
            flipButton
        }
        .padding(.horizontal, 28)
    }

    private var recordButton: some View {
        Button {
            Haptics.record()
            camera.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 76, height: 76)
                if camera.isRecording {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(CameraChrome.record)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(CameraChrome.record)
                        .frame(width: 62, height: 62)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(camera.isSaving || camera.isFinalizingRecording)
        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Start recording")
    }

    private var flipButton: some View {
        Button {
            Haptics.tap()
            flipTurns += 180
            camera.switchCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(flipTurns))
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .opacity(camera.isRecording ? 0 : 1)
        .allowsHitTesting(!camera.isRecording)
        .animation(.easeInOut(duration: 0.35), value: flipTurns)
        .accessibilityLabel(camera.usesFrontCamera ? "Switch to rear camera" : "Switch to front camera")
    }

    private func noticeBanner(_ notice: CameraNotice) -> some View {
        HStack(spacing: 10) {
            Text(notice.message)
                .font(.system(size: 14, weight: .semibold))
            if notice.offersRetry {
                Button("Retry") {
                    camera.retrySave()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CameraChrome.accent)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.black.opacity(notice.isError ? 0.62 : 0.5), in: Capsule())
    }

    private func permissionView(canOpenSettings: Bool, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34, weight: .light))
            Text(canOpenSettings ? "Camera Access" : "Camera Unavailable")
                .font(.system(size: 22, weight: .semibold))
            Text(message)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if canOpenSettings {
                Button("Open Settings", action: openSettings)
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
                    .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct RecordingTimer: View {
    var camera: CameraManager

    var body: some View {
        if camera.isRecording {
            HStack(spacing: 7) {
                Circle()
                    .fill(CameraChrome.record)
                    .frame(width: 8, height: 8)
                Text(Self.format(camera.recordingDuration))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .accessibilityLabel("Recording \(Self.format(camera.recordingDuration))")
        }
    }

    private static func format(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private func selectedStopID(stops: [ZoomStop], zoom: CGFloat) -> String? {
    stops.min { abs($0.displayZoom - zoom) < abs($1.displayZoom - zoom) }?.id
}

private func zoomTitle(stop: ZoomStop, selected: Bool, precise: CGFloat) -> String {
    let value = selected ? precise : stop.displayZoom
    let shown = abs(value - stop.displayZoom) < 0.08 ? stop.displayZoom : value
    let number = formatZoom(shown)
    return selected ? number + "×" : number
}

private func formatZoom(_ value: CGFloat) -> String {
    let tenths = (value * 10).rounded() / 10
    if abs(tenths - tenths.rounded()) < 0.001 {
        return String(Int(tenths.rounded()))
    }
    return String(format: "%.1f", tenths)
}

@MainActor
enum Haptics {
    static func record() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
}
