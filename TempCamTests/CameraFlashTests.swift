import XCTest
@testable import TempCam

/// The simulator has no camera, so the manager stays on its default front position.
@MainActor
final class CameraFlashTests: XCTestCase {
    func testFrontCameraAlwaysOffersFlash() {
        let camera = CameraManager(photoLibrary: FakePhotoLibrary())

        XCTAssertTrue(camera.usesFrontCamera)
        XCTAssertTrue(camera.isFlashAvailable, "Selfie camera uses the screen as its flash")
        XCTAssertFalse(camera.isFlashOn)
    }

    func testToggleFlashOnFrontCameraUsesScreenLight() {
        let camera = CameraManager(photoLibrary: FakePhotoLibrary())

        camera.toggleFlash()
        XCTAssertTrue(camera.isFrontFlashOn)
        XCTAssertTrue(camera.isFlashOn)
        XCTAssertFalse(camera.isTorchOn, "Front flash must not touch the rear torch")

        camera.toggleFlash()
        XCTAssertFalse(camera.isFrontFlashOn)
        XCTAssertFalse(camera.isFlashOn)
    }

    func testSwitchingCameraTurnsFrontFlashOff() {
        let camera = CameraManager(photoLibrary: FakePhotoLibrary())
        camera.toggleFlash()

        camera.switchCamera()

        XCTAssertFalse(camera.isFrontFlashOn)
    }
}
