import XCTest
@testable import NearbyPrototype

private final class ResponseStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let size = request.url!.path == "/valid" ? 32 : 8192
        let declared = request.url!.path == "/declared" ? size : -1
        client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: declared, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 42, count: size))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UploadStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: Data
        if request.url!.path == "/large" { body = Data(repeating: 42, count: 8192) }
        else { body = Data("{\"id\":\"receipt\",\"state\":\"complete\",\"bytes\":3,\"size\":3,\"sha256\":\"hash\"}".utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: request.url!.path == "/failed" ? 507 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class BoundedResponseTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseStub.self]
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        // Exercise the same delegate used by production metadata requests, not
        // only Foundation's default session.
        return URLSession(configuration: configuration, delegate: PinnedReceiver(pin: String(repeating: "0", count: 64)), delegateQueue: queue)
    }
    func testSmallResponseWithUnknownLengthIsPreserved() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let result = try await BoundedResponse.read(session: session, request: URLRequest(url: URL(string: "https://fixture.invalid/valid")!), limit: 4096)
        XCTAssertEqual(result.0, Data(repeating: 42, count: 32))
    }
    func testOversizedDeclaredAndStreamingResponsesAreRejected() async {
        let session = session(); defer { session.invalidateAndCancel() }
        for path in ["declared", "streaming"] {
            do {
                _ = try await BoundedResponse.read(session: session, request: URLRequest(url: URL(string: "https://fixture.invalid/\(path)")!), limit: 4096)
                XCTFail("Oversized response accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("exceeds"))
            }
        }
    }
    func testProductionUploadDelegateParsesReceiptAndRejectsOversizedOrFailedResponses() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let file = OutgoingFile(url: fileURL, name: "test", size: 3, sha256: "hash")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        let agent = PinnedReceiver(pin: String(repeating: "0", count: 64))
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: agent, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        for path in ["valid", "large", "failed"] {
            var request = URLRequest(url: URL(string: "https://fixture.invalid/\(path)")!)
            request.httpMethod = "PUT"
            do {
                let receipt = try await agent.upload(session: session, request: request, file: file) { _ in }
                XCTAssertEqual(path, "valid")
                XCTAssertTrue(receipt.verifies(file, id: "receipt"))
            } catch {
                XCTAssertNotEqual(path, "valid", "\(error)")
            }
        }
    }
    func testCancelledUploadNeverCreatesTaskInInvalidatedSession() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadStub.self]
        let agent = PinnedReceiver(pin: String(repeating: "0", count: 64))
        let session = URLSession(configuration: config, delegate: agent, delegateQueue: nil)
        session.invalidateAndCancel()
        let cancellation = TransferCancellation(); cancellation.cancel()
        let file = OutgoingFile(url: URL(fileURLWithPath: "/does-not-exist"), name: "x", size: 0, sha256: "x")
        do {
            _ = try await agent.upload(session: session, request: URLRequest(url: URL(string: "https://fixture.invalid/valid")!), file: file, cancellation: cancellation) { _ in }
            XCTFail("Cancelled operation created an upload")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
