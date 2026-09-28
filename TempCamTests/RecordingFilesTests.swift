import XCTest
@testable import TempCam

final class RecordingFilesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingFilesTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, bytes: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    func testCopyMovesClipToOwnedName() throws {
        let source = try file("TempCam-abc.mov", bytes: 8_000)

        let copy = try XCTUnwrap(RecordingFiles.durableCopy(of: source, in: directory))

        XCTAssertTrue(copy.lastPathComponent.hasPrefix(RecordingFiles.savePrefix))
        XCTAssertEqual(copy.pathExtension, "mov")
        XCTAssertEqual(RecordingFiles.size(of: copy), 8_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testAlreadyOwnedClipIsReturnedAsIs() throws {
        let owned = try file("\(RecordingFiles.savePrefix)xyz.mov", bytes: 8_000)

        XCTAssertEqual(RecordingFiles.durableCopy(of: owned, in: directory), owned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.path))
    }

    func testAlreadyOwnedTinyClipIsRejected() throws {
        let owned = try file("\(RecordingFiles.savePrefix)xyz.mov", bytes: 10)

        XCTAssertNil(RecordingFiles.durableCopy(of: owned, in: directory))
    }

    func testTinyClipIsRejectedAndLeavesNoCopy() throws {
        let source = try file("TempCam-small.mov", bytes: Int(RecordingFiles.minimumPlayableBytes))

        XCTAssertNil(RecordingFiles.durableCopy(of: source, in: directory))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(RecordingFiles.savePrefix) }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMissingClipReturnsNil() {
        let missing = directory.appendingPathComponent("TempCam-missing.mov")

        XCTAssertNil(RecordingFiles.durableCopy(of: missing, in: directory))
    }

    func testSizeOfMissingFileIsZero() {
        XCTAssertEqual(RecordingFiles.size(of: directory.appendingPathComponent("nope")), 0)
    }
}
