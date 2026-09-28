import Photos
import XCTest
@testable import TempCam

/// Records calls and replays scripted outcomes in place of the real Photos library.
final class FakePhotoLibrary: PhotoLibrarySaving, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: PHAuthorizationStatus
    private var _saveErrors: [Error?]
    private var _savedURLs: [URL] = []
    private var _savedFilesExisted: [Bool] = []

    init(status: PHAuthorizationStatus = .authorized, saveErrors: [Error?] = []) {
        _status = status
        _saveErrors = saveErrors
    }

    var status: PHAuthorizationStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var savedURLs: [URL] { lock.withLock { _savedURLs } }
    var savedFilesExisted: [Bool] { lock.withLock { _savedFilesExisted } }

    func requestAddAuthorization() async -> PHAuthorizationStatus { status }

    func saveVideo(at url: URL) async throws {
        let error: Error? = lock.withLock {
            _savedURLs.append(url)
            _savedFilesExisted.append(FileManager.default.fileExists(atPath: url.path))
            return _saveErrors.isEmpty ? nil : _saveErrors.removeFirst()
        }
        if let error { throw error }
    }
}

@MainActor
final class CameraManagerSaveTests: XCTestCase {
    private struct Boom: Error {}

    private func finish(_ camera: CameraManager, url: URL, success: Bool = true) async {
        camera.handleRecordingFinished(url: url, success: success)
        await camera.saveTask?.value
    }

    func testSuccessfulSaveShowsConfirmationAndCleansUp() async throws {
        let photos = FakePhotoLibrary()
        let camera = CameraManager(photoLibrary: photos)
        var clipFinished = false
        camera.onClipFinished = { clipFinished = true }
        let url = try TestVideo.makeFile(bytes: 10_000)

        await finish(camera, url: url)

        XCTAssertTrue(clipFinished)
        XCTAssertEqual(photos.savedURLs.count, 1)
        XCTAssertEqual(photos.savedFilesExisted, [true], "Photos must receive a file that exists")
        XCTAssertTrue(photos.savedURLs[0].lastPathComponent.hasPrefix(RecordingFiles.savePrefix))
        XCTAssertEqual(camera.notice, CameraNotice(message: "Saved to Photos", isError: false, offersRetry: false))
        XCTAssertNil(camera.pendingSaveURL)
        XCTAssertFalse(camera.isSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Original recording should be removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: photos.savedURLs[0].path), "Saved copy should be removed")
    }

    func testFinishingResetsRecordingState() async throws {
        let camera = CameraManager(photoLibrary: FakePhotoLibrary())
        let url = try TestVideo.makeFile(bytes: 10_000)

        await finish(camera, url: url)

        XCTAssertFalse(camera.isRecording)
        XCTAssertFalse(camera.isFinalizingRecording)
    }

    func testFailedRecordingDeletesFileAndSkipsSave() async throws {
        let photos = FakePhotoLibrary()
        let camera = CameraManager(photoLibrary: photos)
        var clipFinished = false
        camera.onClipFinished = { clipFinished = true }
        let url = try TestVideo.makeFile(bytes: 10_000)

        await finish(camera, url: url, success: false)

        XCTAssertFalse(clipFinished)
        XCTAssertTrue(photos.savedURLs.isEmpty)
        XCTAssertEqual(camera.notice?.message, "Recording didn't finish")
        XCTAssertEqual(camera.notice?.isError, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMissingRecordingFileReportsFailure() async {
        let photos = FakePhotoLibrary()
        let camera = CameraManager(photoLibrary: photos)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("TempCam-missing-\(UUID()).mov")

        await finish(camera, url: missing)

        XCTAssertTrue(photos.savedURLs.isEmpty)
        XCTAssertEqual(camera.notice?.message, "Recording didn't finish")
    }

    func testTinyRecordingIsReportedUnreadable() async throws {
        let photos = FakePhotoLibrary()
        let camera = CameraManager(photoLibrary: photos)
        let url = try TestVideo.makeFile(bytes: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        await finish(camera, url: url)

        XCTAssertTrue(photos.savedURLs.isEmpty)
        XCTAssertEqual(camera.notice, CameraNotice(message: "The recording couldn't be read", isError: true, offersRetry: true))
    }

    func testDeniedPhotosAccessOffersRetryAndKeepsClip() async throws {
        let photos = FakePhotoLibrary(status: .denied)
        let camera = CameraManager(photoLibrary: photos)
        let url = try TestVideo.makeFile(bytes: 10_000)
        defer { try? FileManager.default.removeItem(at: url) }

        await finish(camera, url: url)

        XCTAssertTrue(photos.savedURLs.isEmpty)
        XCTAssertEqual(camera.notice, CameraNotice(message: "Photos access is needed to save the video", isError: true, offersRetry: true))
        XCTAssertEqual(camera.pendingSaveURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLimitedPhotosAccessStillSaves() async throws {
        let photos = FakePhotoLibrary(status: .limited)
        let camera = CameraManager(photoLibrary: photos)

        await finish(camera, url: try TestVideo.makeFile(bytes: 10_000))

        XCTAssertEqual(photos.savedURLs.count, 1)
        XCTAssertEqual(camera.notice?.message, "Saved to Photos")
    }

    func testPhotosErrorKeepsCopyAndRetrySucceeds() async throws {
        let photos = FakePhotoLibrary(saveErrors: [Boom()])
        let camera = CameraManager(photoLibrary: photos)

        await finish(camera, url: try TestVideo.makeFile(bytes: 10_000))

        XCTAssertEqual(camera.notice, CameraNotice(message: "Couldn't save to Photos", isError: true, offersRetry: true))
        let kept = try XCTUnwrap(camera.pendingSaveURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "Clip must survive for retry")

        camera.retrySave()
        await camera.saveTask?.value

        XCTAssertEqual(photos.savedURLs, [kept, kept], "Retry reuses the durable copy instead of re-copying")
        XCTAssertEqual(camera.notice?.message, "Saved to Photos")
        XCTAssertNil(camera.pendingSaveURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
    }

    func testRetryAfterGrantingAccess() async throws {
        let photos = FakePhotoLibrary(status: .denied)
        let camera = CameraManager(photoLibrary: photos)
        await finish(camera, url: try TestVideo.makeFile(bytes: 10_000))
        XCTAssertTrue(photos.savedURLs.isEmpty)

        photos.status = .authorized
        camera.retrySave()
        await camera.saveTask?.value

        XCTAssertEqual(photos.savedURLs.count, 1)
        XCTAssertEqual(camera.notice?.message, "Saved to Photos")
    }

    func testRetryWithNothingPendingDoesNothing() async {
        let photos = FakePhotoLibrary()
        let camera = CameraManager(photoLibrary: photos)

        camera.retrySave()
        await camera.saveTask?.value

        XCTAssertTrue(photos.savedURLs.isEmpty)
        XCTAssertNil(camera.notice)
    }

    func testNewClipReplacesUnsavedPreviousClip() async throws {
        let photos = FakePhotoLibrary(status: .denied)
        let camera = CameraManager(photoLibrary: photos)
        let first = try TestVideo.makeFile(bytes: 10_000)
        await finish(camera, url: first)
        XCTAssertEqual(camera.pendingSaveURL, first)

        let second = try TestVideo.makeFile(bytes: 10_000)
        defer { try? FileManager.default.removeItem(at: second) }
        await finish(camera, url: second)

        XCTAssertEqual(camera.pendingSaveURL, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "Stale unsaved clip should be removed")
    }

    func testDismissNoticeClearsError() async throws {
        let camera = CameraManager(photoLibrary: FakePhotoLibrary(saveErrors: [Boom()]))
        await finish(camera, url: try TestVideo.makeFile(bytes: 10_000))
        XCTAssertNotNil(camera.notice)

        camera.dismissNotice()

        XCTAssertNil(camera.notice)
        if let pending = camera.pendingSaveURL { try? FileManager.default.removeItem(at: pending) }
    }

    /// End to end with real Photos, driven from the main actor exactly as the stop button does.
    func testStopFlowWithRealPhotoLibraryDoesNotCrash() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw XCTSkip("Photos add access not granted")
        }
        let camera = CameraManager()
        let url = try await TestVideo.make()

        await finish(camera, url: url)

        XCTAssertEqual(camera.notice?.message, "Saved to Photos")
        XCTAssertNil(camera.pendingSaveURL)
    }
}
