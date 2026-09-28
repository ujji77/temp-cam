import Photos
import XCTest
@testable import TempCam

/// Exercises the real Photos framework. Run on a simulator with add-only Photos
/// access granted, e.g. `xcrun simctl privacy booted grant photos-add com.uzair.tempcam`.
/// This is the path that runs when the user presses stop.
final class SystemPhotoLibraryTests: XCTestCase {
    private let library = SystemPhotoLibrary()

    private func requireAddAccess() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw XCTSkip("Photos add access not granted (status \(status.rawValue))")
        }
    }

    func testSaveVideoFromMainActorDoesNotCrash() async throws {
        try requireAddAccess()
        let url = try await TestVideo.make()
        defer { try? FileManager.default.removeItem(at: url) }

        try await Self.saveOnMainActor(library, url)
    }

    func testSaveVideoFromBackgroundTaskDoesNotCrash() async throws {
        try requireAddAccess()
        let url = try await TestVideo.make()
        defer { try? FileManager.default.removeItem(at: url) }

        let library = self.library
        try await Task.detached { try await library.saveVideo(at: url) }.value
    }

    func testSaveMissingFileThrowsInsteadOfCrashing() async throws {
        try requireAddAccess()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).mov")

        do {
            try await Self.saveOnMainActor(library, missing)
            XCTFail("Saving a missing file should throw")
        } catch {
            // Expected: Photos reports an error rather than taking the app down.
        }
    }

    func testRequestAddAuthorizationReturnsCurrentStatus() async {
        let status = await library.requestAddAuthorization()
        XCTAssertNotEqual(status, .notDetermined)
    }

    @MainActor
    private static func saveOnMainActor(_ library: SystemPhotoLibrary, _ url: URL) async throws {
        try await library.saveVideo(at: url)
    }
}
