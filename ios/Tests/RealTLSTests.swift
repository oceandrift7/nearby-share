import XCTest
import CryptoKit
@testable import NearbyPrototype

final class RealTLSTests: XCTestCase {
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
