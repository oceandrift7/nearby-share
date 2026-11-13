import XCTest
import CryptoKit
@testable import NearbyPrototype

final class OutgoingFileTests: XCTestCase {
    func testSnapshotPreservesBytesAndHashEvenIfOriginalChanges() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data((0..<700001).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let file = try OutgoingFile.prepare(source, cancellation: TransferCancellation())
        defer { try? FileManager.default.removeItem(at: file.url) }
        try Data("changed".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: file.url), bytes)
        XCTAssertEqual(file.size, Int64(bytes.count))
        XCTAssertEqual(file.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    func testCancelledPreparationDoesNotLeaveASnapshot() throws {
        let dir = FileManager.default.temporaryDirectory
        let source = dir.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 7, count: 1000).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("nearby-outgoing-") })
        let cancellation = TransferCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try OutgoingFile.prepare(source, cancellation: cancellation))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("nearby-outgoing-") })
        XCTAssertEqual(before, after)
    }
    func testOnlyMatchingCompleteReceiptConfirmsDelivery() throws {
        let file = OutgoingFile(url: URL(fileURLWithPath: "/unused"), name: "x", size: 42, sha256: String(repeating: "a", count: 64))
        func receipt(_ state: String = "complete", bytes: Int64 = 42, hash: String? = nil) -> UploadReceipt {
            UploadReceipt(id: "expected", state: state, bytes: bytes, size: 42, sha256: hash ?? file.sha256, error: nil)
        }
        XCTAssertTrue(receipt().verifies(file, id: "expected"))
        XCTAssertFalse(receipt("receiving").verifies(file, id: "expected"))
        XCTAssertFalse(receipt(bytes: 41).verifies(file, id: "expected"))
        XCTAssertFalse(receipt(hash: "wrong").verifies(file, id: "expected"))
        XCTAssertFalse(receipt().verifies(file, id: "different"))
    }
}
