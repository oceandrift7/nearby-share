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
    let diagnostics: SenderDiagnostics?
    var mode: String? = nil
}

enum TransferError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

enum ConnectionDiagnostics {
    static func describe(_ error: Error, stage: String) -> String {
        let value = error as NSError
        let detail = "\(stage) failed: \(value.localizedDescription) [\(value.domain), code \(value.code)]"
        if value.domain == NEHotspotConfigurationErrorDomain {
            return detail + "\nTry joining the Android network in Settings → Wi-Fi, then return and tap ‘I joined in Settings — inspect file’. Automatic joining requires the Hotspot Configuration entitlement in the installed app and its provisioning profile. This error alone does not prove a signing issue."
        }
        return detail
    }
}

@MainActor
final class TransferModel: ObservableObject {
    @Published var pairing: Pairing?
    @Published var manifest: Manifest?
    @Published var received: URL?
    @Published var busy = false
    @Published var progress: Double = 0
    @Published var status = "Choose Send or Receive on Android. Join using its Wi-Fi code in Camera, then scan its Nearby pairing code here."
    @Published var diagnosticReport = ""
    @Published var manualJoinSuggested = false
    @Published var sending = false
    var androidReceives: Bool { manifest?.mode == "receive" }
    private var cancellation = TransferCancellation()
    private var activeOffer: String?
    let profileStatus = HotspotProfileStatus.installed()
    private var joinResult = "not attempted"
    private var senderReadSummary: String?
    private var agent: PinnedReceiver?
    private var session: URLSession?
    private var host: String?
    private var cancelled = false

    func scan(_ text: String) {
        disconnect()
        // A system Wi-Fi QR is not a pairing code and supplies no TLS identity.
        if text.hasPrefix("WIFI:") {
            status = "That is the Wi-Fi code. Scan it with the iPhone Camera to join. Then show Android's step 2 Nearby code and scan it here."
            return
        }
        do { pairing = try Pairing.parse(text); status = "Pairing scanned. If already connected, tap Inspect current connection. Otherwise join through Camera or Settings first." }
        catch { status = error.localizedDescription }
    }

    func connect(joinNetwork: Bool = true) async {
        guard let pairing, !busy else { return }
        busy = true; cancelled = false; cancellation = TransferCancellation()
        manualJoinSuggested = false
        defer { busy = false }
        var stage = "Wi-Fi join"
        do {
            session?.invalidateAndCancel(); session = nil; agent = nil
            manifest = nil; host = nil; received = nil; senderReadSummary = nil
            if joinNetwork && JoinSettings.canRequestAutomaticJoin(profile: profileStatus) {
                status = "Waiting for Wi-Fi approval…"
                let config = JoinSettings.configuration(for: pairing)
                do { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NEHotspotConfigurationManager.shared.apply(config) { error in
                        if let error = error as NSError?, !(error.domain == NEHotspotConfigurationErrorDomain && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                            continuation.resume(throwing: error)
                        } else { continuation.resume() }
                    }
                }
                    joinResult = "normal join request accepted"
                } catch {
                    let failure = error as NSError
                    joinResult = "automatic join: \(failure.domain), code \(failure.code)"
                    // Some join errors occur even when the user already joined in Settings.
                    // Only a pinned, authorized manifest can establish connection success.
                    guard JoinSettings.shouldInspectAfterFailure(failure) else { throw error }
                    manualJoinSuggested = true
                }
            } else { joinResult = "current connection (Camera / Settings / existing Wi-Fi)" }
            guard !cancelled else { throw CancellationError() }
            stage = "Sender inspection"
            let receiver = PinnedReceiver(pin: pairing.certificateSHA256)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForResource = 3600
            configuration.connectionProxyDictionary = [:]
            configuration.allowsCellularAccess = false
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
            self.agent = receiver; self.session = session
            status = "Checking the nearby device's certificate…"
            var lastFailure = "No response from the sender."
            // A short retry tolerates the Wi-Fi route appearing after the join prompt.
            let attempts = manualJoinSuggested ? 1 : 3
            let deadline = ProcessInfo.processInfo.systemUptime + (manualJoinSuggested ? 4 : 12)
            for attempt in 0..<attempts {
                for candidate in pairing.hosts {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining < 0.1 { break }
                    guard !cancelled else { throw CancellationError() }
                    do {
                        let request = makeRequest(pairing: pairing, host: candidate, path: "manifest", timeout: min(remaining, manualJoinSuggested ? 1 : 4))
                        let (data, response) = try await BoundedResponse.read(session: session, request: request, limit: 65536)
                        guard let http = response as? HTTPURLResponse else { throw TransferError.message("Sender returned no HTTP response.") }
                        guard http.statusCode == 200 else { throw TransferError.message("Sender returned HTTP \(http.statusCode). Scan a fresh Android code if sharing was restarted.") }
                        guard data.count <= 65536 else { throw TransferError.message("Sender metadata exceeds the supported size.") }
                        let file = try JSONDecoder().decode(Manifest.self, from: data)
                        guard file.mode == nil || file.mode == "send" || file.mode == "receive" else { throw TransferError.message("Unsupported transfer mode. Update Nearby on both phones.") }
                        guard (0...1_099_511_627_776).contains(file.size), (1...1024).contains(file.name.utf8.count),
                              file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw TransferError.message("Sender metadata is invalid.") }
                        guard !cancelled else { throw CancellationError() }
                        self.host = candidate; self.manifest = file
                        manualJoinSuggested = false
                        updateReport()
                        status = file.mode == "receive" ? "Android receiver verified. Choose a file to send, then accept it on Android." : "Encrypted connection verified. Accept the file to start."
                        return
                    } catch {
                        if cancelled { throw CancellationError() }
                        lastFailure = ConnectionDiagnostics.describe(error, stage: "Sender request")
                    }
                }
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: 500_000_000) }
            }
            throw TransferError.message("Could not inspect the Android file. Confirm the iPhone is on the Android hotspot and Local Network access is allowed. Keep Android open.\nLast attempt: \(lastFailure)")
        } catch {
            session?.invalidateAndCancel(); session = nil; agent = nil
            status = cancelled ? "Cancelled." : ConnectionDiagnostics.describe(error, stage: stage)
            if !cancelled { manualJoinSuggested = true }
            updateReport(error: error)
        }
    }

    func receive() async {
        guard let pairing, let manifest, !androidReceives, let host, let session, let agent, !busy else { return }
        busy = true; cancelled = false; cancellation = TransferCancellation(); progress = 0
        received = nil; senderReadSummary = nil
        defer { busy = false }
        do {
            try TransferStorage.requireSpace(manifest.size, at: FileManager.default.temporaryDirectory)
            status = "Receiving…"
            let transferID = UUID().uuidString
            var request = makeRequest(pairing: pairing, host: host, path: "file", timeout: 120)
            request.setValue(transferID, forHTTPHeaderField: "X-Nearby-Transfer-ID")
            let result = try await agent.download(session: session, request: request, manifest: manifest, cancellation: cancellation) { [weak self] count in
                Task { @MainActor in
                    guard let self, !self.cancelled, self.busy, self.received == nil else { return }
                    self.progress = manifest.size == 0 ? 1 : Double(count) / Double(manifest.size)
                    self.status = "Received \(ByteCountFormatter.string(fromByteCount: count, countStyle: .file))."
                }
            }
            guard !cancelled else { try? FileManager.default.removeItem(at: result.url); throw CancellationError() }
            received = result.url; progress = 1
            // Optional v0.2.0 instrumentation, outside the transfer timer. An old
            // sender, missing record, or timeout must never fail a verified file.
            let statsRequest = makeRequest(pairing: pairing, host: host, path: "transfer-stats?id=\(transferID)", timeout: 2)
            if let (data, response) = try? await BoundedResponse.read(session: session, request: statsRequest, limit: 4096),
               (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096,
               let measurement = try? JSONDecoder().decode(SenderReadMeasurement.self, from: data) {
                senderReadSummary = measurement.summary(expectedBytes: manifest.size)
            }
            guard !cancelled else { status = "Transfer verified and saved. Diagnostic check cancelled."; return }
            updateReport(result: result)
            status = String(format: "Verified complete. Transfer: %.2f s · %.1f MB/s. Checksum: %.2f s. Preparation and Wi-Fi setup excluded.", result.seconds, Double(manifest.size) / result.seconds / 1_000_000, result.verificationSeconds)
        } catch {
            status = cancelled ? "Cancelled. No incomplete file was saved." : error.localizedDescription
            updateReport(error: error)
        }
    }

    func send(_ source: URL) async {
        guard androidReceives, let pairing, let host, let session, let agent, !busy else { return }
        busy = true; sending = true; cancelled = false; progress = 0
        cancellation = TransferCancellation()
        let cancellation = self.cancellation
        var prepared: OutgoingFile?
        defer {
            if let prepared { try? FileManager.default.removeItem(at: prepared.url) }
            busy = false; sending = false; activeOffer = nil
        }
        do {
            status = "Preparing file and checksum…"
            let file = try await Task.detached(priority: .userInitiated) {
                try OutgoingFile.prepare(source, cancellation: cancellation)
            }.value
            prepared = file
            try cancellation.check()
            var offer = makeRequest(pairing: pairing, host: host, path: "offer", timeout: 10)
            offer.httpMethod = "POST"
            offer.setValue("application/json", forHTTPHeaderField: "Content-Type")
            offer.httpBody = try JSONSerialization.data(withJSONObject: ["name": file.name, "size": file.size, "sha256": file.sha256])
            let (data, response) = try await BoundedResponse.read(session: session, request: offer, limit: 4096)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw TransferError.message("Android could not accept a new offer. Check its storage and stop any previous receive session, then pair again.")
            }
            let receipt = try JSONDecoder().decode(UploadReceipt.self, from: data)
            guard UUID(uuidString: receipt.id) != nil, receipt.state == "waiting" else { throw TransferError.message("Invalid offer response.") }
            activeOffer = receipt.id
            status = "Waiting for Android to accept \(file.name)…"
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while true {
                try cancellation.check()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw TransferError.message("No acceptance after two minutes. Try sending again.") }
                let request = makeRequest(pairing: pairing, host: host, path: "offer?id=\(receipt.id)", timeout: 5)
                let (data, response) = try await BoundedResponse.read(session: session, request: request, limit: 4096)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TransferError.message("Android receive session ended. Pair again.") }
                let state = try JSONDecoder().decode(UploadReceipt.self, from: data)
                guard state.id == receipt.id else { throw TransferError.message("Android returned a different offer.") }
                if state.state == "accepted" { break }
                guard state.state == "waiting" else { throw TransferError.message(state.error ?? "Android \(state.state) the transfer.") }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            try cancellation.check()
            status = "Sending \(file.name)…"
            var request = makeRequest(pairing: pairing, host: host, path: "upload?id=\(receipt.id)", timeout: 120)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(file.size), forHTTPHeaderField: "Content-Length")
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await agent.upload(session: session, request: request, file: file, cancellation: cancellation) { [weak self] bytes in
                Task { @MainActor in
                    guard let self, self.sending, !self.cancelled else { return }
                    self.progress = file.size == 0 ? 1 : min(1, Double(bytes) / Double(file.size))
                    self.status = bytes >= file.size ? "Android is verifying the file…" : "Sent \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))."
                }
            }
            guard result.verifies(file, id: receipt.id) else { throw TransferError.message("Android did not confirm a verified save. Check Android before retrying.") }
            try cancellation.check()
            let seconds = max(ProcessInfo.processInfo.systemUptime - start, 0.001)
            progress = 1
            status = String(format: "Android verified and saved the file. %.2f s · %.1f MB/s. Tap Save received file on Android to choose a location.", seconds, Double(file.size) / seconds / 1_000_000)
            diagnosticReport = String(format: "Nearby diagnostic report\nApp: 0.2.0\nDirection: iPhone → Android\nVerified by Android: yes\nFile bytes: %lld\nUpload and acknowledgement: %.3f s\nThroughput: %.3f MB/s\nPreparation, acceptance and Wi-Fi setup excluded.", file.size, seconds, Double(file.size) / seconds / 1_000_000)
        } catch {
            // Best effort revoke even after the original session was cancelled.
            // Android also discards incomplete uploads when its socket closes.
            if let id = activeOffer, !cancelled {
                var request = makeRequest(pairing: pairing, host: host, path: "offer?id=\(id)", timeout: 2)
                request.httpMethod = "DELETE"
                _ = try? await BoundedResponse.read(session: session, request: request, limit: 4096)
            }
            status = cancelled ? "Cancelled. Check Android if it had already finished saving." : error.localizedDescription
        }
    }

    func cancel() {
        cancelled = true
        cancellation.cancel()
        // Revoke an offer on a separate short-lived pinned session because the
        // transfer session must be cancelled immediately (including a PUT).
        if let id = activeOffer, let pairing, let host {
            var request = makeRequest(pairing: pairing, host: host, path: "offer?id=\(id)", timeout: 3)
            request.httpMethod = "DELETE"
            let config = URLSessionConfiguration.ephemeral
            config.allowsCellularAccess = false; config.connectionProxyDictionary = [:]
            let revoke = URLSession(configuration: config, delegate: PinnedReceiver(pin: pairing.certificateSHA256), delegateQueue: nil)
            Task { _ = try? await BoundedResponse.read(session: revoke, request: request, limit: 4096); revoke.invalidateAndCancel() }
        }
        if let session {
            // Serialize invalidation with queued upload/download creation. The
            // cancellation flag interrupts hashing immediately on its own.
            session.delegateQueue.addOperation { session.invalidateAndCancel() }
        }
        session = nil; agent = nil; manifest = nil; host = nil
        // iOS controls the Wi-Fi approval dialog; cancellation is checked when it returns.
        status = "Cancelling… If the Wi-Fi prompt is open, dismiss it."
    }

    func disconnect() {
        cancellation.cancel()
        session?.invalidateAndCancel(); session = nil; agent = nil
        if let pairing, JoinSettings.canRequestAutomaticJoin(profile: profileStatus) {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: pairing.ssid)
        }
        pairing = nil; manifest = nil; received = nil; host = nil; progress = 0
        senderReadSummary = nil
        diagnosticReport = ""; manualJoinSuggested = false; joinResult = "not attempted"
        status = "Pairing cleared. To leave a network joined in Camera or Settings, use Settings → Wi-Fi. Previously received files remain in Files → On My iPhone → Nearby prototype."
    }

    private func makeRequest(pairing: Pairing, host: String, path: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(host):\(pairing.port)/\(path)")!)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func updateReport(result: ReceiveResult? = nil, error: Error? = nil) {
        var lines = ["Nearby diagnostic report", "Receiver app: 0.2.0", "iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Hotspot capability: \(profileStatus.rawValue)", "Profile check is diagnostic; installed signature not verified.",
                     "Join mode: \(joinResult)"]
        if let manifest {
            lines.append("File bytes: \(manifest.size)")
            lines.append(manifest.diagnostics?.summary ?? "Sender diagnostics: unavailable (update Android to 0.2.0)")
            if let result {
                lines.append(String(format: "Verified: yes\nTransfer: %.3f s\nThroughput: %.3f MB/s\nChecksum: %.3f s", result.seconds, Double(manifest.size) / result.seconds / 1_000_000, result.verificationSeconds))
                lines.append(result.timing.summary)
                lines.append(senderReadSummary ?? "Sender snapshot read timing: unavailable")
            }
        }
        if let error { let value = error as NSError; lines.append("Failure: \(value.domain), code \(value.code)") }
        lines.append("Speed excludes file preparation and Wi-Fi setup. Internet availability not inferred.")
        diagnosticReport = lines.joined(separator: "\n")
    }
}

struct ReceiveResult { let url: URL; let seconds: Double; let verificationSeconds: Double; var timing = TransferTiming() }

// Serial delegate queue owns download state. Certificate pin is obtained from the
// code physically scanned on the sender, never from the network being authenticated.
final class PinnedReceiver: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate, URLSessionDataDelegate {
    private let pin: String
    private var cancellation = TransferCancellation()
    private var uploadContinuation: CheckedContinuation<UploadReceipt, Error>?
    private var uploadData = Data()
    private var uploadProgress: ((Int64) -> Void)?
    private var uploadLastProgress: TimeInterval = 0
    private var uploadFailure: Error?
    private var continuation: CheckedContinuation<ReceiveResult, Error>?
    private var expected: Manifest?
    private var started: TimeInterval = 0
    private var result: Result<ReceiveResult, Error>?
    private var onProgress: ((Int64) -> Void)?
    private var lastProgress: TimeInterval = 0
    private var timing = TransferTiming()
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

    func download(session: URLSession, request: URLRequest, manifest: Manifest, cancellation: TransferCancellation,
                  progress: @escaping (Int64) -> Void) async throws -> ReceiveResult {
        try await withCheckedThrowingContinuation { continuation in
            session.delegateQueue.addOperation {
                do { try cancellation.check() }
                catch { continuation.resume(throwing: error); return }
                self.cancellation = cancellation
                self.continuation = continuation; self.expected = manifest; self.result = nil
                self.onProgress = progress; self.started = ProcessInfo.processInfo.systemUptime
                self.lastProgress = 0
                self.timing = TransferTiming()
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
            while let chunk = try handle.read(upToCount: 262144), !chunk.isEmpty { try cancellation.check(); hash.update(data: chunk) }
            try cancellation.check()
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
        if task is URLSessionUploadTask, let pending = uploadContinuation {
            uploadContinuation = nil; uploadProgress = nil
            defer { uploadData = Data(); uploadFailure = nil }
            if let failure = uploadFailure ?? error { pending.resume(throwing: failure) }
            else if (task.response as? HTTPURLResponse)?.statusCode != 200 {
                pending.resume(throwing: TransferError.message("Android could not save this upload. Check its screen and storage."))
            } else {
                do { pending.resume(returning: try JSONDecoder().decode(UploadReceipt.self, from: uploadData)) }
                catch { pending.resume(throwing: error) }
            }
            return
        }
        guard task is URLSessionDownloadTask, let continuation else { return }
        self.continuation = nil; onProgress = nil; expected = nil
        if let error {
            if case .success(let saved) = result { try? FileManager.default.removeItem(at: saved.url) }
            continuation.resume(throwing: error)
        } else {
            continuation.resume(with: result.map { $0.map { saved in
                var complete = saved; complete.timing = self.timing; return complete
            } } ?? .failure(TransferError.message("No completed file received.")))
        }
        result = nil
    }

    func upload(session: URLSession, request: URLRequest, file: OutgoingFile,
                cancellation: TransferCancellation = TransferCancellation(),
                progress: @escaping (Int64) -> Void) async throws -> UploadReceipt {
        try await withCheckedThrowingContinuation { continuation in
            session.delegateQueue.addOperation {
                do { try cancellation.check() }
                catch { continuation.resume(throwing: error); return }
                self.uploadContinuation = continuation; self.uploadData = Data(); self.uploadFailure = nil
                self.uploadProgress = progress; self.uploadLastProgress = 0
                session.uploadTask(with: request, fromFile: file.url).resume()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard task is URLSessionUploadTask else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - uploadLastProgress >= 0.25 || totalBytesSent == totalBytesExpectedToSend {
            uploadLastProgress = now; uploadProgress?(totalBytesSent)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask is URLSessionUploadTask, uploadContinuation != nil else { return }
        guard uploadData.count + data.count <= 4096 else {
            uploadFailure = TransferError.message("Android's acknowledgement exceeds the supported size.")
            dataTask.cancel(); return
        }
        uploadData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard task is URLSessionDownloadTask, let last = metrics.transactionMetrics.last else { return }
        timing = TransferTiming(firstByte: TransferTiming.interval(last.fetchStartDate, last.responseStartDate),
                                body: TransferTiming.interval(last.responseStartDate, last.responseEndDate),
                                tls: TransferTiming.interval(last.secureConnectionStartDate, last.secureConnectionEndDate),
                                reused: last.isReusedConnection)
    }
}
