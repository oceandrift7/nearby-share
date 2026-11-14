import XCTest
import CryptoKit
@testable import NearbyPrototype

final class DownloadCheckpointTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
    private func manifest(_ bytes: Data) -> Manifest {
        Manifest(name: "test.bin", size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), diagnostics: nil)
    }
    @discardableResult private func chunk(_ bytes: Data, in directory: URL) throws -> URL {
        let path = directory.appendingPathComponent(UUID().uuidString); try bytes.write(to: path); return path
    }

    func testReopeningCheckpointRestoresProgressAndTruncatesUncommittedTail() throws {
        try withDirectory { directory in
            let bytes = Data(repeating: 90, count: 2 * 1024 * 1024)
            let file = manifest(bytes)
            let checkpoint = try DownloadCheckpoint(pin: "sender", manifest: file, directory: directory)
            try checkpoint.append(chunk(bytes.prefix(1024 * 1024), in: directory), cancellation: TransferCancellation())
            let output = try FileHandle(forWritingTo: checkpoint.part)
            try output.seekToEnd(); try output.write(contentsOf: Data(repeating: 1, count: 100)); try output.close()
            let restored = try DownloadCheckpoint(pin: "sender", manifest: file, directory: directory)
            XCTAssertEqual(restored.offset, 1024 * 1024)
            XCTAssertEqual(try Data(contentsOf: restored.part).count, 1024 * 1024)
            try restored.append(chunk(bytes.suffix(1024 * 1024), in: directory), cancellation: TransferCancellation())
            let result = try restored.finish(cancellation: TransferCancellation())
            defer { try? FileManager.default.removeItem(at: result.0) }
            XCTAssertEqual(try Data(contentsOf: result.0), bytes)
        }
    }
    func testDifferentSenderOrDifferentFileCannotReuseCheckpoint() throws {
        try withDirectory { directory in
            let bytes = Data(repeating: 90, count: 1024 * 1024)
            let checkpoint = try DownloadCheckpoint(pin: "sender-one", manifest: manifest(bytes), directory: directory)
            try checkpoint.append(chunk(bytes, in: directory), cancellation: TransferCancellation())
            XCTAssertEqual(try DownloadCheckpoint(pin: "sender-two", manifest: manifest(bytes), directory: directory).offset, 0)
            XCTAssertEqual(try DownloadCheckpoint(pin: "sender-one", manifest: manifest(Data(repeating: 91, count: bytes.count)), directory: directory).offset, 0)
        }
    }
    func testCancelledAppendKeepsLastCheckpointAndDiscardRemovesIt() throws {
        try withDirectory { directory in
            let bytes = Data(repeating: 90, count: 1024 * 1024)
            let checkpoint = try DownloadCheckpoint(pin: "sender", manifest: manifest(bytes), directory: directory)
            let cancellation = TransferCancellation(); cancellation.cancel()
            XCTAssertThrowsError(try checkpoint.append(chunk(bytes, in: directory), cancellation: cancellation))
            XCTAssertEqual(checkpoint.offset, 0)
            XCTAssertEqual(try Data(contentsOf: checkpoint.part).count, 0)
            checkpoint.discard()
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.part.path))
        }
    }
    func testCorruptSavedPrefixFailsWholeHashAndIsDiscarded() throws {
        try withDirectory { directory in
            let bytes = Data(repeating: 90, count: 1024 * 1024)
            let checkpoint = try DownloadCheckpoint(pin: "sender", manifest: manifest(bytes), directory: directory)
            try checkpoint.append(chunk(Data(repeating: 1, count: bytes.count), in: directory), cancellation: TransferCancellation())
            XCTAssertThrowsError(try checkpoint.finish(cancellation: TransferCancellation()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.part.path))
        }
    }
    func testExactRangeResponseIsRequiredBeforeAppending() throws {
        let range = ResumeRange(start: 1024, end: 2047, total: 4096, hash: "expected")
        func response(_ code: Int, _ contentRange: String, _ hash: String = "expected") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://127.0.0.1/file")!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": contentRange, "ETag": "\"\(hash)\""])!
        }
        XCTAssertTrue(range.accepts(response(206, "bytes 1024-2047/4096")))
        XCTAssertFalse(range.accepts(response(200, "bytes 1024-2047/4096")))
        XCTAssertFalse(range.accepts(response(206, "bytes 0-1023/4096")))
        XCTAssertFalse(range.accepts(response(206, "bytes 1024-2047/8192")))
        XCTAssertFalse(range.accepts(response(206, "bytes 1024-2047/4096", "different")))
    }
    func testEmptyFileCanFinishWithoutAnyNetworkChunks() throws {
        try withDirectory { directory in
            let checkpoint = try DownloadCheckpoint(pin: "sender", manifest: manifest(Data()), directory: directory)
            let saved = try checkpoint.finish(cancellation: TransferCancellation())
            defer { try? FileManager.default.removeItem(at: saved.0) }
            XCTAssertEqual(try Data(contentsOf: saved.0), Data())
        }
    }
    func testInvalidCheckpointMetadataCannotSeekBeyondFile() throws {
        try withDirectory { directory in
            let file = manifest(Data(repeating: 90, count: 1024*1024))
            let checkpoint = try DownloadCheckpoint(pin: "sender", manifest: file, directory: directory)
            let metadata = checkpoint.part.deletingPathExtension().appendingPathExtension("json")
            try Data("{\"offset\":9223372036854775807}".utf8).write(to: metadata)
            XCTAssertEqual(try DownloadCheckpoint(pin: "sender", manifest: file, directory: directory).offset, 0)
        }
    }
}
