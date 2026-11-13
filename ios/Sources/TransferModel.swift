import Foundation
import Combine
import NetworkExtension
import CryptoKit
import Security

struct Pairing: Decodable {
    let v: Int
    let ssid: String
    let password: String
    let hosts: [String]
    let port: Int
    let token: String
    let certificateSHA256: String

    static func parse(_ string: String) throws -> Pairing {
        guard string.utf8.count <= 4096, let data = string.data(using: .utf8) else { throw TransferError.message("Invalid pairing code.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.v == 1, (1...32).contains(value.ssid.utf8.count),
              (8...63).contains(value.password.utf8.count), (1...65535).contains(value.port),
              value.token.count == 64, value.certificateSHA256.count == 64,
              value.token.unicodeScalars.allSatisfy({ hex.contains($0) }),
              value.certificateSHA256.unicodeScalars.allSatisfy({ hex.contains($0) }),
              (1...16).contains(value.hosts.count), value.hosts.allSatisfy(Self.isPrivateIPv4)
        else { throw TransferError.message("Unsupported or invalid pairing code.") }
        return value
    }

    static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let bytes = parts.compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 172 && (16...31).contains(bytes[1]))
    }
}

struct Manifest: Decodable {
    let name: String
    let size: Int64
    let sha256: String
}

enum TransferError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

@MainActor
final class TransferModel: ObservableObject {
    @Published var pairing: Pairing?
    @Published var manifest: Manifest?
    @Published var received: URL?
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var status = "Choose a file on Android, then scan its code here."
    private var agent: PinnedReceiver?
    private var session: URLSession?
    private var host: String?
    private var cancelled = false

    func scan(_ text: String) {
        disconnect()
        do { pairing = try Pairing.parse(text); status = "Pairing code scanned. Review and join the network." }
        catch { status = error.localizedDescription }
    }

    func connect() async {
        guard let pairing, !busy else { return }
        busy = true; cancelled = false
        defer { busy = false }
        do {
            status = "Waiting for Wi-Fi approval…"
            let config = NEHotspotConfiguration(ssid: pairing.ssid, passphrase: pairing.password, isWEP: false)
            config.joinOnce = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NEHotspotConfigurationManager.shared.apply(config) { error in
                    if let error = error as NSError?, !(error.domain == NEHotspotConfigurationErrorDomain && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                        continuation.resume(throwing: error)
                    } else { continuation.resume() }
                }
            }
            guard !cancelled else { throw CancellationError() }
            let receiver = PinnedReceiver(pin: pairing.certificateSHA256)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForResource = 3600
            configuration.connectionProxyDictionary = [:]
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
            self.agent = receiver; self.session = session
            status = "Checking the nearby device's certificate…"
            // A short retry tolerates the Wi-Fi route appearing after the join prompt.
            for attempt in 0..<3 {
                for candidate in pairing.hosts {
                    guard !cancelled else { throw CancellationError() }
                    do {
                        let request = makeRequest(pairing: pairing, host: candidate, path: "manifest", timeout: 4)
                        let (data, response) = try await session.data(for: request)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 65536 else { continue }
                        let file = try JSONDecoder().decode(Manifest.self, from: data)
                        guard (0...1_099_511_627_776).contains(file.size), (1...1024).contains(file.name.utf8.count),
                              file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { continue }
                        guard !cancelled else { throw CancellationError() }
                        self.host = candidate; self.manifest = file
                        status = "Encrypted connection verified. Accept the file to start."
                        return
                    } catch { if cancelled { throw CancellationError() } }
                }
                if attempt < 2 { try await Task.sleep(nanoseconds: 500_000_000) }
            }
            throw TransferError.message("Could not reach the Android app. Allow Local Network access in Settings, keep Android open, and scan a fresh code. No certificate bypass was used.")
        } catch {
            session?.invalidateAndCancel(); session = nil; agent = nil
            status = cancelled ? "Cancelled." : error.localizedDescription
        }
    }

    func receive() async {
        guard let pairing, let manifest, let host, let session, let agent, !busy else { return }
        busy = true; cancelled = false; progress = 0
        defer { busy = false }
        do {
            status = "Receiving…"
            let request = makeRequest(pairing: pairing, host: host, path: "file", timeout: 120)
            let result = try await agent.download(session: session, request: request, manifest: manifest) { [weak self] count in
                Task { @MainActor in
                    guard let self, !self.cancelled, self.busy, self.received == nil else { return }
                    self.progress = manifest.size == 0 ? 1 : Double(count) / Double(manifest.size)
                    self.status = "Received \(ByteCountFormatter.string(fromByteCount: count, countStyle: .file))."
                }
            }
            guard !cancelled else { try? FileManager.default.removeItem(at: result.url); throw CancellationError() }
            received = result.url; progress = 1
            status = String(format: "Verified complete. Transfer: %.2f s · %.1f MB/s. Checksum: %.2f s. Preparation and Wi-Fi setup excluded.", result.seconds, Double(manifest.size) / result.seconds / 1_000_000, result.verificationSeconds)
        } catch { status = cancelled ? "Cancelled. No incomplete file was saved." : error.localizedDescription }
    }

    func cancel() {
        cancelled = true
        session?.invalidateAndCancel()
        session = nil; agent = nil; manifest = nil; host = nil
        // iOS controls the Wi-Fi approval dialog; cancellation is checked when it returns.
        status = "Cancelling… If the Wi-Fi prompt is open, dismiss it."
    }

    func disconnect() {
        session?.invalidateAndCancel(); session = nil; agent = nil
        if let pairing { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: pairing.ssid) }
        pairing = nil; manifest = nil; received = nil; host = nil; progress = 0
        status = "Disconnected. Previously received files remain in Files → On My iPhone → Nearby prototype."
    }

    private func makeRequest(pairing: Pairing, host: String, path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(host):\(pairing.port)/\(path)")!)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }
}

struct ReceiveResult { let url: URL; let seconds: Double; let verificationSeconds: Double }

// Serial delegate queue owns download state. Certificate pin is obtained from the
// code physically scanned on the sender, never from the network being authenticated.
final class PinnedReceiver: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    private let pin: String
    private var continuation: CheckedContinuation<ReceiveResult, Error>?
    private var expected: Manifest?
    private var started: TimeInterval = 0
    private var result: Result<ReceiveResult, Error>?
    private var onProgress: ((Int64) -> Void)?
    private var lastProgress: TimeInterval = 0
    init(pin: String) { self.pin = pin }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let hash = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard hash == pin else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the bearer token to another endpoint.
    }

    func download(session: URLSession, request: URLRequest, manifest: Manifest,
                  progress: @escaping (Int64) -> Void) async throws -> ReceiveResult {
        try await withCheckedThrowingContinuation { continuation in
            session.delegateQueue.addOperation {
                self.continuation = continuation; self.expected = manifest; self.result = nil
                self.onProgress = progress; self.started = ProcessInfo.processInfo.systemUptime
                self.lastProgress = 0
                session.downloadTask(with: request).resume()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let expected, totalBytesWritten > expected.size { downloadTask.cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgress >= 0.25 {
            lastProgress = now
            onProgress?(totalBytesWritten)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let transferSeconds = max(ProcessInfo.processInfo.systemUptime - started, 0.001)
        do {
            guard let expected, let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw TransferError.message("Sender refused the transfer. Scan a new code.")
            }
            let verificationStart = ProcessInfo.processInfo.systemUptime
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
            guard size == expected.size else { throw TransferError.message("Incomplete file: size mismatch.") }
            let handle = try FileHandle(forReadingFrom: location)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 262144), !chunk.isEmpty { hash.update(data: chunk) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == expected.sha256 else { throw TransferError.message("Integrity check failed. File was not saved.") }
            let verificationSeconds = ProcessInfo.processInfo.systemUptime - verificationStart
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let clean = String(expected.name.map { "/\\:\0".contains($0) || $0.isNewline ? "_" : $0 }.prefix(120))
            let destination = documents.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(clean)")
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(ReceiveResult(url: destination, seconds: transferSeconds, verificationSeconds: verificationSeconds))
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task is URLSessionDownloadTask, let continuation else { return }
        self.continuation = nil; onProgress = nil; expected = nil
        if let error {
            if case .success(let saved) = result { try? FileManager.default.removeItem(at: saved.url) }
            continuation.resume(throwing: error)
        } else { continuation.resume(with: result ?? .failure(TransferError.message("No completed file received."))) }
        result = nil
    }
}
