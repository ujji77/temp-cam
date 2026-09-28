import AVFoundation
import os
import Photos
import UIKit

struct ZoomStop: Identifiable, Equatable, Sendable {
    let id: String
    let displayZoom: CGFloat
    let deviceZoom: CGFloat
}

struct CameraNotice: Equatable {
    var message: String
    var isError: Bool
    var offersRetry: Bool
}

private struct PipelineSnapshot: Sendable {
    var usesFrontCamera: Bool
    var zoomStops: [ZoomStop]
    var displayZoom: CGFloat
    var minDisplayZoom: CGFloat
    var maxDisplayZoom: CGFloat
    var isTorchAvailable: Bool
    var isTorchOn: Bool
    var hasMicrophone: Bool
    var unavailableMessage: String?
    var configurationGeneration: Int
}

/// Owns permissions, the capture session, and Photos export.
///
/// Video is written by `AVCaptureMovieFileOutput` from the camera input only.
/// The teleprompter is not a capture source and cannot appear in the file.
@MainActor
@Observable
final class CameraManager {
    let session = AVCaptureSession()

    private(set) var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var usesFrontCamera = true
    private(set) var isRecording = false
    private(set) var isFinalizingRecording = false
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var isTorchAvailable = false
    private(set) var isTorchOn = false
    private(set) var zoomStops: [ZoomStop] = []
    private(set) var displayZoom: CGFloat = 1
    private(set) var configurationGeneration = 0
    private(set) var notice: CameraNotice?
    private(set) var unavailableMessage: String?
    private(set) var isSaving = false
    private(set) var capturesAudio = false

    var minDisplayZoom: CGFloat = 1
    var maxDisplayZoom: CGFloat = 1

    var onClipFinished: (() -> Void)?

    private let pipeline: CapturePipeline
    private let photoLibrary: PhotoLibrarySaving
    private var recordingClock: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private(set) var pendingSaveURL: URL?
    /// The in-flight save, exposed so tests can await it.
    private(set) var saveTask: Task<Void, Never>?
    private var pinchBaseline: CGFloat = 1
    private var didWarnAboutMicrophone = false
    private var prepared = false

    init(photoLibrary: PhotoLibrarySaving = SystemPhotoLibrary()) {
        self.photoLibrary = photoLibrary
        pipeline = CapturePipeline(session: session)
        pipeline.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in
                self?.apply(snapshot)
            }
        }
        pipeline.onRecordingStarted = { [weak self] in
            Task { @MainActor in
                self?.confirmRecordingDidStart()
            }
        }
        pipeline.onRecordingFinished = { [weak self] url, success in
            Task { @MainActor in
                self?.handleRecordingFinished(url: url, success: success)
            }
        }
        pipeline.onRecordingIdle = { [weak self] in
            Task { @MainActor in
                self?.isRecording = false
                self?.isFinalizingRecording = false
                self?.stopClock()
            }
        }
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true

        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let videoGranted: Bool
        if videoStatus == .notDetermined {
            videoGranted = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            videoGranted = videoStatus == .authorized
        }
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        guard videoGranted else {
            Log.camera.error("Camera access not granted")
            return
        }

        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let audioGranted: Bool
        if audioStatus == .notDetermined {
            audioGranted = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            audioGranted = audioStatus == .authorized
        }

        Log.camera.info("Starting capture session, audio: \(audioGranted, privacy: .public)")
        pipeline.start(includeAudio: audioGranted)
        _ = await photoLibrary.requestAddAuthorization()
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        pipeline.attachPreviewLayer(layer)
    }

    func setInterfaceActive(_ active: Bool) {
        guard authorization == .authorized else { return }
        pipeline.setRunning(active)
    }

    func switchCamera() {
        guard !isRecording, !isFinalizingRecording else { return }
        if isTorchOn {
            isTorchOn = false
        }
        pipeline.switchCamera()
    }

    func toggleTorch() {
        guard isTorchAvailable, !usesFrontCamera else { return }
        isTorchOn.toggle()
        pipeline.setTorch(isTorchOn)
    }

    func selectZoom(_ stop: ZoomStop) {
        displayZoom = stop.displayZoom
        pipeline.setDeviceZoom(stop.deviceZoom)
    }

    func handlePinch(scale: CGFloat, state: UIGestureRecognizer.State) {
        switch state {
        case .began:
            pinchBaseline = displayZoom
        case .changed:
            setDisplayZoom(pinchBaseline * scale)
        default:
            break
        }
    }

    func focus(at devicePoint: CGPoint) {
        pipeline.focus(at: devicePoint)
    }

    func toggleRecording() {
        guard !isSaving, !isFinalizingRecording else { return }
        if isRecording {
            Log.recording.info("Stop pressed after \(self.recordingDuration, format: .fixed(precision: 1), privacy: .public)s")
            isFinalizingRecording = true
            isRecording = false
            stopClock()
            pipeline.stopRecording()
            return
        }
        if !capturesAudio, !didWarnAboutMicrophone {
            didWarnAboutMicrophone = true
            showNotice(CameraNotice(
                message: "Recording without microphone audio",
                isError: false,
                offersRetry: false
            ))
        }
        Log.recording.info("Record pressed, audio: \(self.capturesAudio, privacy: .public)")
        isRecording = true
        recordingDuration = 0
        startClock()
        pipeline.startRecording()
    }

    func retrySave() {
        guard let url = pendingSaveURL, !isSaving else { return }
        Log.photos.info("Retrying save of \(url.lastPathComponent, privacy: .public)")
        saveTask = Task { await saveToPhotos(url) }
    }

    func dismissNotice() {
        notice = nil
    }

    private func setDisplayZoom(_ value: CGFloat) {
        guard maxDisplayZoom > minDisplayZoom else { return }
        displayZoom = min(max(value, minDisplayZoom), maxDisplayZoom)
        pipeline.setDisplayZoom(displayZoom)
    }

    private func apply(_ snapshot: PipelineSnapshot) {
        usesFrontCamera = snapshot.usesFrontCamera
        zoomStops = snapshot.zoomStops
        displayZoom = snapshot.displayZoom
        minDisplayZoom = snapshot.minDisplayZoom
        maxDisplayZoom = snapshot.maxDisplayZoom
        isTorchAvailable = snapshot.isTorchAvailable
        isTorchOn = snapshot.isTorchOn
        capturesAudio = snapshot.hasMicrophone
        configurationGeneration = snapshot.configurationGeneration
        unavailableMessage = snapshot.unavailableMessage
    }

    private func confirmRecordingDidStart() {
        if !isRecording {
            isRecording = true
            startClock()
        }
    }

    /// Internal rather than private so tests can drive the stop -> save flow without a camera.
    func handleRecordingFinished(url: URL, success: Bool) {
        isRecording = false
        isFinalizingRecording = false
        stopClock()
        let exists = FileManager.default.fileExists(atPath: url.path)
        Log.recording.info("""
            Recording finished: \(url.lastPathComponent, privacy: .public) \
            success=\(success, privacy: .public) exists=\(exists, privacy: .public) \
            bytes=\(RecordingFiles.size(of: url), privacy: .public)
            """)
        guard success, exists else {
            if success == false {
                try? FileManager.default.removeItem(at: url)
            }
            showNotice(CameraNotice(
                message: "Recording didn't finish",
                isError: true,
                offersRetry: false
            ))
            return
        }
        onClipFinished?()
        if let previous = pendingSaveURL, previous != url {
            try? FileManager.default.removeItem(at: previous)
        }
        pendingSaveURL = url
        saveTask = Task { await saveToPhotos(url) }
    }

    private func saveToPhotos(_ url: URL) async {
        isSaving = true
        defer { isSaving = false }

        let status = await photoLibrary.requestAddAuthorization()
        guard status == .authorized || status == .limited else {
            Log.photos.error("Can't save, Photos access is \(status.logDescription, privacy: .public)")
            showNotice(CameraNotice(
                message: "Photos access is needed to save the video",
                isError: true,
                offersRetry: true
            ))
            return
        }

        let stableURL = await Task.detached(priority: .userInitiated) {
            RecordingFiles.durableCopy(of: url)
        }.value
        guard let stableURL else {
            Log.photos.error("Recording at \(url.lastPathComponent, privacy: .public) couldn't be copied or was too small")
            showNotice(CameraNotice(
                message: "The recording couldn't be read",
                isError: true,
                offersRetry: true
            ))
            return
        }
        pendingSaveURL = stableURL

        do {
            try await photoLibrary.saveVideo(at: stableURL)
            if pendingSaveURL == stableURL {
                pendingSaveURL = nil
            }
            try? FileManager.default.removeItem(at: stableURL)
            showNotice(CameraNotice(message: "Saved to Photos", isError: false, offersRetry: false))
        } catch {
            Log.photos.error("Photo library save failed: \(String(describing: error), privacy: .public)")
            showNotice(CameraNotice(
                message: "Couldn't save to Photos",
                isError: true,
                offersRetry: true
            ))
        }
    }

    private func startClock() {
        recordingClock?.cancel()
        let start = Date()
        recordingClock = Task { @MainActor in
            while !Task.isCancelled {
                recordingDuration = Date().timeIntervalSince(start)
                let elapsed = recordingDuration
                let fraction = elapsed.truncatingRemainder(dividingBy: 1)
                try? await Task.sleep(for: .seconds(max(0.05, 1 - fraction)))
            }
        }
    }

    private func stopClock() {
        recordingClock?.cancel()
        recordingClock = nil
    }

    private func showNotice(_ notice: CameraNotice) {
        self.notice = notice
        noticeTask?.cancel()
        guard !notice.isError else { return }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            if self.notice == notice {
                self.notice = nil
            }
        }
    }
}


/// Session-queue owner for AVFoundation. Sendable so the capture queue can use it
/// without hopping back onto the main actor for every device call.
private final class CapturePipeline: NSObject, @unchecked Sendable, AVCaptureFileOutputRecordingDelegate {
    static let logger = Log.camera

    let session: AVCaptureSession
    var onSnapshot: (@Sendable (PipelineSnapshot) -> Void)?
    var onRecordingStarted: (@Sendable () -> Void)?
    var onRecordingFinished: (@Sendable (URL, Bool) -> Void)?
    var onRecordingIdle: (@Sendable () -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.tempcam.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var position: AVCaptureDevice.Position = .front
    private var includeAudio = false
    private var hasMicrophone = false
    private var configured = false
    private var generation = 0
    private var didInstallRuntimeObserver = false
    private var captureRotationAngle: CGFloat = 270
    private var rotationChangesAllowed = true
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private weak var coordinatedDevice: AVCaptureDevice?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?

    init(session: AVCaptureSession) {
        self.session = session
        super.init()
    }

    func start(includeAudio: Bool) {
        sessionQueue.async {
            self.includeAudio = includeAudio
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.publishSnapshot()
        }
    }

    func setRunning(_ running: Bool) {
        sessionQueue.async {
            guard self.configured else { return }
            if running {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            } else if !self.movieOutput.isRecording, self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func switchCamera() {
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            self.turnTorchOffOnQueue()
            self.position = self.position == .back ? .front : .back
            self.captureRotationAngle = self.position == .front ? 270 : 90
            self.rebuildVideoInput()
            self.installRotationCoordinator()
            self.publishSnapshot()
        }
    }

    func setTorch(_ enabled: Bool) {
        sessionQueue.async {
            guard let device = self.videoDevice, device.hasTorch, device.isTorchAvailable else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
            } catch {
                Self.logger.error("Torch change failed: \(error.localizedDescription, privacy: .public)")
            }
            self.publishSnapshot()
        }
    }

    func setDeviceZoom(_ deviceZoom: CGFloat) {
        sessionQueue.async {
            self.apply(deviceZoom: deviceZoom)
        }
    }

    func setDisplayZoom(_ displayZoom: CGFloat) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            let multiplier = device.displayVideoZoomFactorMultiplier
            guard multiplier > 0 else { return }
            self.apply(deviceZoom: displayZoom / multiplier)
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                Self.logger.error("Focus failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        sessionQueue.async {
            self.previewLayer = layer
            self.installRotationCoordinator()
        }
    }

    func startRecording() {
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            guard self.session.isRunning else {
                Log.recording.error("Can't start recording, session isn't running")
                self.onRecordingIdle?()
                return
            }
            self.rotationChangesAllowed = false
            self.teardownRotationCoordinator()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TempCam-\(UUID().uuidString)")
                .appendingPathExtension("mov")
            Log.recording.info("Movie output starting: \(url.lastPathComponent, privacy: .public)")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                Log.recording.info("Movie output stopping")
                self.movieOutput.stopRecording()
            } else {
                Log.recording.notice("Stop requested but movie output wasn't recording")
                self.onRecordingIdle?()
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        onRecordingStarted?()
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let finishedSuccessfully: Bool
        if let error = error as NSError? {
            finishedSuccessfully = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
            if finishedSuccessfully {
                Log.recording.notice("Recording finished with non-fatal error: \(error, privacy: .public)")
            } else {
                Log.recording.error("Recording failed: \(error, privacy: .public)")
            }
        } else {
            finishedSuccessfully = true
        }
        sessionQueue.async {
            self.rotationChangesAllowed = true
            self.installRotationCoordinator()
            self.onRecordingFinished?(outputFileURL, finishedSuccessfully)
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        rebuildVideoInput(insideConfiguration: true)
        addAudioInputIfNeeded()
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        movieOutput.movieFragmentInterval = .invalid
        applyOutputConnectionSettings()
        session.commitConfiguration()
        installRuntimeObserverIfNeeded()
        installRotationCoordinator()
        configured = videoInput != nil
    }

    private func rebuildVideoInput(insideConfiguration: Bool = false) {
        if !insideConfiguration {
            session.beginConfiguration()
        }
        defer {
            if !insideConfiguration {
                applyOutputConnectionSettings()
                session.commitConfiguration()
            }
        }

        if let videoInput {
            session.removeInput(videoInput)
            self.videoInput = nil
        }

        guard let device = Self.preferredDevice(position: position) else {
            videoDevice = nil
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                videoDevice = nil
                return
            }
            session.addInput(input)
            videoInput = input
            videoDevice = device
            configure(device)
        } catch {
            Self.logger.error("Camera configuration failed: \(error.localizedDescription, privacy: .public)")
            videoDevice = nil
        }
    }

    private func addAudioInputIfNeeded() {
        guard includeAudio else {
            hasMicrophone = false
            return
        }
        guard let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(input) else {
            hasMicrophone = false
            return
        }
        session.addInput(input)
        hasMicrophone = true
    }

    private func configure(_ device: AVCaptureDevice) {
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }

        do {
            try device.lockForConfiguration()
        } catch {
            Self.logger.error("Could not lock camera: \(error.localizedDescription, privacy: .public)")
            return
        }
        defer { device.unlockForConfiguration() }

        let format = device.activeFormat
        if format.supportedColorSpaces.contains(.HLG_BT2020) {
            device.activeColorSpace = .HLG_BT2020
        }

        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
        if device.isGeometricDistortionCorrectionSupported {
            device.isGeometricDistortionCorrectionEnabled = true
        }

        let multiplier = device.displayVideoZoomFactorMultiplier
        if multiplier > 0 {
            let oneX = 1 / multiplier
            let clamped = min(max(oneX, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.videoZoomFactor = clamped
        }
    }

    private func teardownRotationCoordinator() {
        previewRotationObservation?.invalidate()
        captureRotationObservation?.invalidate()
        previewRotationObservation = nil
        captureRotationObservation = nil
        rotationCoordinator = nil
        coordinatedDevice = nil
    }

    /// Angles come from the coordinator. Connections are only changed on the session queue.
    private func installRotationCoordinator() {
        guard rotationChangesAllowed, !movieOutput.isRecording else { return }
        guard let device = videoDevice, let previewLayer else { return }
        guard coordinatedDevice !== device || rotationCoordinator == nil else { return }

        teardownRotationCoordinator()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        coordinatedDevice = device

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            self?.sessionQueue.async {
                self?.applyPreviewRotation(angle)
            }
        }
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async {
                guard let self, self.rotationChangesAllowed, !self.movieOutput.isRecording else { return }
                guard abs(self.captureRotationAngle - angle) > 0.5 else { return }
                self.captureRotationAngle = angle
                self.applyCaptureRotation()
            }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard rotationChangesAllowed, !movieOutput.isRecording, let connection = previewLayer?.connection else { return }
        if connection.isVideoRotationAngleSupported(angle),
           abs(connection.videoRotationAngle - angle) > 0.5 {
            connection.videoRotationAngle = angle
        }
        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        let mirrored = position == .front
        if connection.isVideoMirrored != mirrored {
            connection.isVideoMirrored = mirrored
        }
    }

    /// Portrait capture rotation is a track matrix. The teleprompter is not part of this connection.
    private func applyOutputConnectionSettings() {
        applyCaptureRotation()
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoStabilizationSupported {
            let format = videoDevice?.activeFormat
            if format?.isVideoStabilizationModeSupported(.standard) == true {
                connection.preferredVideoStabilizationMode = .standard
            } else if format?.isVideoStabilizationModeSupported(.cinematic) == true {
                connection.preferredVideoStabilizationMode = .cinematic
            } else {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
    }

    private func applyCaptureRotation() {
        guard !movieOutput.isRecording, let connection = movieOutput.connection(with: .video) else { return }
        let angle = captureRotationAngle
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        if abs(connection.videoRotationAngle - angle) > 0.5 {
            connection.videoRotationAngle = angle
        }
        guard connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
    }

    private func apply(deviceZoom: CGFloat) {
        guard let device = videoDevice else { return }
        let clamped = min(max(deviceZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
        } catch {
            Self.logger.error("Zoom failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func turnTorchOffOnQueue() {
        guard let device = videoDevice, device.hasTorch, device.torchMode == .on else { return }
        try? device.lockForConfiguration()
        device.torchMode = .off
        device.unlockForConfiguration()
    }

    private func installRuntimeObserverIfNeeded() {
        guard !didInstallRuntimeObserver else { return }
        didInstallRuntimeObserver = true
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.camera.error("Capture session runtime error: \(String(describing: error), privacy: .public)")
            self.sessionQueue.async {
                guard !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }
    }

    private func publishSnapshot() {
        generation += 1
        let snapshot: PipelineSnapshot
        if let device = videoDevice {
            let zoom = Self.zoomState(for: device)
            let torchAvailable = device.hasTorch && device.isTorchAvailable && position == .back
            snapshot = PipelineSnapshot(
                usesFrontCamera: position == .front,
                zoomStops: zoom.stops,
                displayZoom: zoom.displayZoom,
                minDisplayZoom: zoom.minDisplayZoom,
                maxDisplayZoom: zoom.maxDisplayZoom,
                isTorchAvailable: torchAvailable,
                isTorchOn: device.torchMode == .on,
                hasMicrophone: hasMicrophone,
                unavailableMessage: nil,
                configurationGeneration: generation
            )
        } else {
            let message: String
            #if targetEnvironment(simulator)
            message = "Open TempCam on your iPhone to record. The Simulator doesn't include a camera."
            #else
            message = "The camera couldn't be started."
            #endif
            snapshot = PipelineSnapshot(
                usesFrontCamera: position == .front,
                zoomStops: [],
                displayZoom: 1,
                minDisplayZoom: 1,
                maxDisplayZoom: 1,
                isTorchAvailable: false,
                isTorchOn: false,
                hasMicrophone: hasMicrophone,
                unavailableMessage: message,
                configurationGeneration: generation
            )
        }
        onSnapshot?(snapshot)
    }

    private static func preferredDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return discovery.devices.first
    }

    private static func zoomState(for device: AVCaptureDevice) -> (
        stops: [ZoomStop],
        displayZoom: CGFloat,
        minDisplayZoom: CGFloat,
        maxDisplayZoom: CGFloat
    ) {
        let multiplier = device.displayVideoZoomFactorMultiplier
        guard multiplier > 0.001 else {
            return ([], 1, 1, 1)
        }

        let minDisplay = device.minAvailableVideoZoomFactor * multiplier
        let deviceMaxDisplay = device.maxAvailableVideoZoomFactor * multiplier
        let pinchMax = min(deviceMaxDisplay, 12)

        func deviceZoom(for displayZoom: CGFloat) -> CGFloat {
            displayZoom / multiplier
        }

        var chosen: [CGFloat] = []
        func append(_ value: CGFloat) {
            let clamped = min(max(value, minDisplay), deviceMaxDisplay)
            guard !chosen.contains(where: { abs($0 - clamped) < 0.12 }) else { return }
            chosen.append(clamped)
        }

        append(minDisplay)
        if max(minDisplay, 1) <= deviceMaxDisplay + 0.05 {
            append(1)
        }
        if deviceMaxDisplay >= 2 {
            append(2)
        }
        if let tele = device.virtualDeviceSwitchOverVideoZoomFactors
            .map({ CGFloat(truncating: $0) * multiplier })
            .filter({ $0 > 2.2 })
            .max() {
            append(tele)
        }

        chosen.sort()
        if chosen.count > 4 {
            let last = chosen[chosen.count - 1]
            var compact: [CGFloat] = [chosen[0]]
            if chosen.contains(where: { abs($0 - 1) < 0.12 }) { compact.append(1) }
            if chosen.contains(where: { abs($0 - 2) < 0.12 }) { compact.append(2) }
            if !compact.contains(where: { abs($0 - last) < 0.12 }) { compact.append(last) }
            chosen = compact.sorted()
        }

        let stops = chosen.map { value in
            ZoomStop(
                id: String(format: "%.2f", value),
                displayZoom: value,
                deviceZoom: min(max(deviceZoom(for: value), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            )
        }
        let current = device.videoZoomFactor * multiplier
        return (stops, current, minDisplay, pinchMax)
    }
}

/// File handling for finished clips. Pure file-system logic, so it is unit tested directly.
enum RecordingFiles {
    /// Clips smaller than this are treated as unreadable (a movie header alone is larger).
    static let minimumPlayableBytes: Int64 = 4096
    static let savePrefix = "TempCam-Save-"

    /// Moves the movie output's file to a name we own so a retry can find it later.
    /// Returns nil when the clip is missing, too small, or can't be copied.
    static func durableCopy(of url: URL, in directory: URL = FileManager.default.temporaryDirectory) -> URL? {
        if url.lastPathComponent.hasPrefix(savePrefix) {
            return size(of: url) > minimumPlayableBytes ? url : nil
        }
        let destination = directory
            .appendingPathComponent("\(savePrefix)\(UUID().uuidString)")
            .appendingPathExtension("mov")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            guard size(of: destination) > minimumPlayableBytes else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
            try? FileManager.default.removeItem(at: url)
            return destination
        } catch {
            Log.photos.error("Copying recording failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
