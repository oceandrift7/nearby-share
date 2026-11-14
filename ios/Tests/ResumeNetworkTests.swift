import XCTest
import CryptoKit
@testable import NearbyPrototype

final class ResumeNetworkTests: XCTestCase {
    private func data() -> Data { Data((0..<(3*1024*1024+17)).map { UInt8($0 % 251) }) }
    private func manifest(_ bytes: Data) -> Manifest {
        Manifest(name: "resumed.bin", size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), diagnostics: nil)
    }
    private func pin() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "localhost", withExtension: "der"))
        return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func request(_ fault: String, run: String) -> URLRequest {
        var value = URLRequest(url: URL(string: "https://127.0.0.1:19443/resume-test?fault=\(fault)&run=\(run)")!)
        value.timeoutInterval = 15
        return value
    }
    private func session(_ pin: String) -> (URLSession, PinnedReceiver) {
        let agent = PinnedReceiver(pin: pin)
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        return (URLSession(configuration: configuration, delegate: agent, delegateQueue: queue), agent)
    }

    func testDroppedConnectionResumesFromDiskWithNewClientAndVerifiesWholeFile() async throws {
        let bytes = data(); let file = manifest(bytes); let pin = try pin()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = UUID().uuidString
        let (first, firstAgent) = session(pin)
        do {
            _ = try await ResumableDownload.receive(pin: pin, manifest: file, request: request("drop", run: run), session: first,
                agent: firstAgent, cancellation: TransferCancellation(), directory: directory) { _ in }
            XCTFail("Connection interruption was not reported")
        } catch {
            XCTAssertEqual(try DownloadCheckpoint(pin: pin, manifest: file, directory: directory).offset, 1024*1024)
        }
        first.invalidateAndCancel()
        let (second, secondAgent) = session(pin); defer { second.invalidateAndCancel() }
        let saved = try await ResumableDownload.receive(pin: pin, manifest: file, request: request("drop", run: run), session: second,
            agent: secondAgent, cancellation: TransferCancellation(), directory: directory) { _ in }
        defer { try? FileManager.default.removeItem(at: saved.url) }
        XCTAssertEqual(saved.resumedBytes, 1024*1024)
        XCTAssertEqual(try Data(contentsOf: saved.url), bytes)
    }

    func testPauseKeepsCheckpointAndResumeCompletes() async throws {
        let bytes = data(); let file = manifest(bytes); let pin = try pin()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, agent) = session(pin); defer { session.invalidateAndCancel() }
        let cancellation = TransferCancellation()
        let request = request("", run: UUID().uuidString)
        do {
            _ = try await ResumableDownload.receive(pin: pin, manifest: file, request: request, session: session, agent: agent,
                cancellation: cancellation, directory: directory, checkpointed: { _ in cancellation.cancel() }) { _ in }
            XCTFail("Pause was ignored")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try DownloadCheckpoint(pin: pin, manifest: file, directory: directory).offset, 1024*1024)
        let saved = try await ResumableDownload.receive(pin: pin, manifest: file, request: request, session: session, agent: agent,
            cancellation: TransferCancellation(), directory: directory) { _ in }
        defer { try? FileManager.default.removeItem(at: saved.url) }
        XCTAssertEqual(saved.resumedBytes, 1024*1024)
        XCTAssertEqual(try Data(contentsOf: saved.url), bytes)
    }

    func testWrongRangeIdentityAndIgnoredRangeCannotBeAppended() async throws {
        let file = manifest(data()); let pin = try pin()
        for fault in ["ignore", "wrong-range", "wrong-file"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (session, agent) = session(pin); defer { session.invalidateAndCancel() }
            do {
                _ = try await ResumableDownload.receive(pin: pin, manifest: file, request: request(fault, run: UUID().uuidString), session: session,
                    agent: agent, cancellation: TransferCancellation(), directory: directory) { _ in }
                XCTFail("Invalid range response accepted: \(fault)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Sender refused"), "Unexpected error: \(error)")
                XCTAssertEqual(try DownloadCheckpoint(pin: pin, manifest: file, directory: directory).offset, 0)
            }
        }
    }
    func testCorruptChunkFailsFinalHashAndDiscardsAllProgress() async throws {
        let file = manifest(data()); let pin = try pin()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, agent) = session(pin); defer { session.invalidateAndCancel() }
        do {
            _ = try await ResumableDownload.receive(pin: pin, manifest: file, request: request("corrupt", run: UUID().uuidString), session: session,
                agent: agent, cancellation: TransferCancellation(), directory: directory) { _ in }
            XCTFail("Corrupt file was saved")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Integrity check failed")) }
        XCTAssertEqual(try DownloadCheckpoint(pin: pin, manifest: file, directory: directory).offset, 0)
    }

    func testPauseDuringActiveChunkKeepsOnlyCommittedBytesAndSameSessionCanResume() async throws {
        let bytes = data(); let file = manifest(bytes); let pin = try pin()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, agent) = session(pin); defer { session.invalidateAndCancel() }
        let cancellation = TransferCancellation()
        do {
            _ = try await ResumableDownload.receive(pin: pin, manifest: file, request: request("slow", run: UUID().uuidString), session: session,
                agent: agent, cancellation: cancellation, directory: directory) { bytes in
                    if bytes > 1024*1024 {
                        cancellation.cancel(); agent.cancelDownload(session: session, cancellation: cancellation)
                    }
                }
            XCTFail("Pause was ignored")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
        }
        XCTAssertEqual(try DownloadCheckpoint(pin: pin, manifest: file, directory: directory).offset, 1024*1024)
        let saved = try await ResumableDownload.receive(pin: pin, manifest: file, request: request("", run: UUID().uuidString), session: session,
            agent: agent, cancellation: TransferCancellation(), directory: directory) { _ in }
        defer { try? FileManager.default.removeItem(at: saved.url) }
        XCTAssertEqual(saved.resumedBytes, 1024*1024)
        XCTAssertEqual(try Data(contentsOf: saved.url), bytes)
    }
}
