import XCTest
import CryptoKit
@testable import NearbyPrototype

final class RealTLSTests: XCTestCase {
    func testRealTLSDownloadRejectsWrongHashAndTruncatedFileWithoutSaving() async throws {
        let certificate = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "localhost", withExtension: "der")))
        let pin = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: documents.path))
        for path in ["bad-hash", "truncated"] {
            let agent = PinnedReceiver(pin: pin)
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
            let session = URLSession(configuration: config, delegate: agent, delegateQueue: queue)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "https://127.0.0.1:19443/\(path)")!)
            request.timeoutInterval = 5
            let manifest = Manifest(name: "must-not-save.bin", size: path == "truncated" ? 8192 : 4096, sha256: String(repeating: "0", count: 64), diagnostics: nil)
            do {
                let saved = try await agent.download(session: session, request: request, manifest: manifest, cancellation: TransferCancellation()) { _ in }
                try? FileManager.default.removeItem(at: saved.url)
                XCTFail("Invalid file was saved: \(path)")
            } catch {
                XCTAssertEqual(before, Set(try FileManager.default.contentsOfDirectory(atPath: documents.path)))
            }
        }
    }
    func testRealTLSDownloadSpeedAndIntegrity() async throws {
        let bundle = Bundle(for: Self.self)
        let certificate = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "localhost", withExtension: "der")))
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "benchmark", withExtension: "json")))) as! [String: Int]
        let mib = try XCTUnwrap(settings["mib"])
        XCTAssertTrue([8, 64, 256].contains(mib))
        let chunk = Data(repeating: 90, count: 262144)
        var hash = SHA256()
        for _ in 0..<(mib * 4) { hash.update(data: chunk) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let pin = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        let agent = PinnedReceiver(pin: pin)
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: agent, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let size = Int64(mib) * 1024 * 1024
        let manifest = Manifest(name: "benchmark.bin", size: size, sha256: digest, diagnostics: nil)
        let result = try await agent.download(session: session, request: URLRequest(url: URL(string: "https://127.0.0.1:19443/benchmark")!), manifest: manifest, cancellation: TransferCancellation()) { _ in }
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? NSNumber)?.int64Value, size)
        let report: [String: Any] = ["platform": "iOS simulator", "path": "production iPhone receiver; Python TLS fixture", "bytes": size,
            "seconds": result.seconds, "checksumSeconds": result.verificationSeconds, "MBps": Double(size) / result.seconds / 1e6,
            "verified": true, "physicalWiFi": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("NEARBY_BENCHMARK " + String(decoding: data, as: UTF8.self))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "iOS-transfer-benchmark.json"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testBoundedMetadataUsesPinForSelfSignedTLSAndRejectsWrongPin() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "localhost", withExtension: "der"))
        let certificate = try Data(contentsOf: url)
        let pin = SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined()
        for correct in [true, false] {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            let agent = PinnedReceiver(pin: correct ? pin : String(repeating: "0", count: 64))
            let session = URLSession(configuration: config, delegate: agent, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: URL(string: "https://127.0.0.1:19443/manifest")!)
            request.timeoutInterval = 5
            do {
                let (data, response) = try await BoundedResponse.read(session: session, request: request, limit: 4096)
                XCTAssertTrue(correct, "Wrong certificate pin was accepted")
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(String(data: data, encoding: .utf8), "{\"ok\":true}")
            } catch { if correct { throw error } }
        }
    }
}
