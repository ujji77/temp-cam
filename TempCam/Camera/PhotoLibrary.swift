import Foundation
import os
import Photos

/// The Photos operations `CameraManager` depends on. Tests substitute a fake.
protocol PhotoLibrarySaving: Sendable {
    /// Returns add-only authorization, prompting the user if it is undetermined.
    func requestAddAuthorization() async -> PHAuthorizationStatus
    func saveVideo(at url: URL) async throws
}

struct PhotoSaveFailure: Error {}

/// Photos runs both the change block and the completion handler on its own background
/// queues. Under Swift 6, a closure written inside a main-actor context (including
/// `DispatchQueue.main.async { }`) inherits main-actor isolation, and the runtime traps
/// with `dispatch_assert_queue` when Photos calls it off the main thread. Every closure
/// handed to Photos here is `@Sendable` and created in a nonisolated context for that reason.
struct SystemPhotoLibrary: PhotoLibrarySaving {
    func requestAddAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        Log.photos.info("Requesting add-only Photos access")
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        Log.photos.info("Photos access result: \(status.logDescription, privacy: .public)")
        return status
    }

    func saveVideo(at url: URL) async throws {
        Log.photos.info("Adding video to Photos: \(url.lastPathComponent, privacy: .public)")
        let changes: @Sendable () -> Void = {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @Sendable (Bool, Error?) -> Void = { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoSaveFailure())
                }
            }
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        }
        Log.photos.info("Photos accepted \(url.lastPathComponent, privacy: .public)")
    }
}

extension PHAuthorizationStatus {
    var logDescription: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}
