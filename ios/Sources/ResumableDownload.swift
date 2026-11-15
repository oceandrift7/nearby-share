import Foundation
import CryptoKit

struct ResumeRange {
    let start: Int64
    let end: Int64
    let total: Int64
    let hash: String
    var length: Int64 { end - start + 1 }
    func accepts(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 206 && response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(total)" &&
        response.value(forHTTPHeaderField: "ETag") == "\"\(hash)\""
    }
}

/// Private, durable checkpoints. Only complete chunks are committed; no names,
/// network credentials or URLs are persisted. Final whole-file hash is mandatory.
final class DownloadCheckpoint {
    static let chunkSize: Int64 = 1024 * 1024
    private struct State: Codable { let offset: Int64 }
    let part: URL
    private let metadata: URL
    let manifest: Manifest
    private(set) var offset: Int64 = 0

    static func identity(pin: String, manifest: Manifest) -> String {
        SHA256.hash(data:Data("\(pin)|\(manifest.sha256)|\(manifest.size)".utf8)).map { String(format:"%02x",$0) }.joined()
    }

    static func savedOffset(pin: String, manifest: Manifest, directory: URL? = nil) -> Int64 {
        guard let root = try? directory ?? Self.directory() else { return 0 }
        let key = identity(pin:pin,manifest:manifest)
        let metadata = root.appendingPathComponent(key + ".json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath:metadata.path)[.size] as? NSNumber)?.intValue, size <= 256,
              let data = try? Data(contentsOf:metadata), let state = try? JSONDecoder().decode(State.self,from:data),
              state.offset >= 0, state.offset <= manifest.size,
              state.offset == manifest.size || state.offset % chunkSize == 0,
              let length = (try? FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(key + ".part").path)[.size] as? NSNumber)?.int64Value,
              length >= state.offset else { return 0 }
        return state.offset
    }

    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = base.appendingPathComponent("IncomingParts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        return directory
    }

    init(pin: String, manifest: Manifest, directory: URL? = nil) throws {
        self.manifest = manifest
        let directory = try directory ?? Self.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = Self.identity(pin:pin,manifest:manifest)
        part = directory.appendingPathComponent(key + ".part")
        metadata = directory.appendingPathComponent(key + ".json")
        let length = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? -1
        if let data = try? Data(contentsOf: metadata), data.count <= 256,
           let state = try? JSONDecoder().decode(State.self, from: data),
           state.offset >= 0, state.offset <= manifest.size, length >= state.offset,
           state.offset == manifest.size || state.offset % Self.chunkSize == 0 {
            offset = state.offset
            let handle = try FileHandle(forWritingTo: part); defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(offset))
        } else {
            try? FileManager.default.removeItem(at: metadata)
            try? FileManager.default.removeItem(at: part)
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw TransferError.message("Could not create download checkpoint.") }
        }
    }

    func append(_ chunk: URL, cancellation: TransferCancellation) throws {
        let length = (try FileManager.default.attributesOfItem(atPath: chunk.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard length == min(Self.chunkSize, manifest.size - offset), length > 0 else { throw TransferError.message("Invalid download chunk.") }
        let output = try FileHandle(forWritingTo: part); defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: chunk); defer { try? input.close() }
        do {
            try output.seek(toOffset: UInt64(offset))
            while let bytes = try input.read(upToCount: 262144), !bytes.isEmpty {
                try cancellation.check(); try output.write(contentsOf: bytes)
            }
            try cancellation.check()
            try output.synchronize()
            try JSONEncoder().encode(State(offset: offset + length)).write(to: metadata, options: .atomic)
            offset += length
        } catch {
            try? output.truncate(atOffset: UInt64(offset)); try? output.synchronize()
            throw error
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: part)
        try? FileManager.default.removeItem(at: metadata)
        offset = 0
    }

    func finish(cancellation: TransferCancellation) throws -> (URL, Double) {
        guard offset == manifest.size else { throw TransferError.message("Download is not complete.") }
        let started = ProcessInfo.processInfo.systemUptime
        let input = try FileHandle(forReadingFrom: part); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 262144), !data.isEmpty { try cancellation.check(); hash.update(data: data) }
        try cancellation.check()
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == manifest.sha256 else { discard(); throw TransferError.message("Integrity check failed. Saved progress was discarded; start again.") }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var name = ""
        for character in manifest.name {
            let next = "/\\:\0".contains(character) || character.isNewline ? "_" : String(character)
            if name.utf8.count + next.utf8.count > 180 { break }
            name += next
        }
        if name.isEmpty { name = "Shared file" }
        let destination = documents.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(name)")
        try FileManager.default.moveItem(at: part, to: destination)
        try? FileManager.default.removeItem(at: metadata)
        return (destination, seconds)
    }
}

enum ResumableDownload {
    static func receive(pin: String, manifest: Manifest, request: URLRequest, session: URLSession,
                        agent: PinnedReceiver, cancellation: TransferCancellation,
                        directory: URL? = nil, checkpointed: ((Int64) -> Void)? = nil,
                        progress: @escaping (Int64) -> Void) async throws -> ReceiveResult {
        let checkpoint = try DownloadCheckpoint(pin: pin, manifest: manifest, directory: directory)
        let resumed = checkpoint.offset
        try TransferStorage.requireSpace(manifest.size - resumed + DownloadCheckpoint.chunkSize, at: checkpoint.part.deletingLastPathComponent())
        let started = ProcessInfo.processInfo.systemUptime
        var requests = 0
        var reusedConnections = 0
        progress(resumed)
        while checkpoint.offset < manifest.size {
            try cancellation.check()
            let range = ResumeRange(start: checkpoint.offset, end: min(checkpoint.offset + DownloadCheckpoint.chunkSize, manifest.size) - 1,
                                    total: manifest.size, hash: manifest.sha256)
            var chunkRequest = request
            chunkRequest.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
            chunkRequest.setValue("\"\(manifest.sha256)\"", forHTTPHeaderField: "If-Match")
            let chunk = try await agent.download(session: session, request: chunkRequest,
                manifest: Manifest(name: "chunk", size: range.length, sha256: "", diagnostics: nil), cancellation: cancellation, range: range) { count in
                    progress(range.start + count)
                }
            defer { try? FileManager.default.removeItem(at: chunk.url) }
            requests += 1
            if chunk.timing.reused { reusedConnections += 1 }
            try cancellation.check()
            try checkpoint.append(chunk.url, cancellation: cancellation)
            checkpointed?(checkpoint.offset)
            progress(checkpoint.offset)
        }
        let seconds = max(ProcessInfo.processInfo.systemUptime - started, 0.001)
        let (url, verification) = try checkpoint.finish(cancellation: cancellation)
        return ReceiveResult(url: url, seconds: seconds, verificationSeconds: verification, resumedBytes: resumed,
                             rangeRequests: requests, reusedRangeConnections: reusedConnections)
    }
}
