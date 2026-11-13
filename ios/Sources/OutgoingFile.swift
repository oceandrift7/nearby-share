import Foundation
import CryptoKit

final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = stopped; lock.unlock()
        if value { throw CancellationError() }
    }
}

struct OutgoingFile {
    let url: URL
    let name: String
    let size: Int64
    let sha256: String

    static func prepare(_ source: URL, cancellation: TransferCancellation) throws -> OutgoingFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw TransferError.message("Choose a regular file.") }
        let directory = FileManager.default.temporaryDirectory
        try TransferStorage.requireSpace(Int64(values.fileSize ?? 0), at: directory)
        let destination = directory.appendingPathComponent("nearby-outgoing-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw TransferError.message("Could not prepare temporary storage.")
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var hash = SHA256()
            var size: Int64 = 0
            var nextSpaceCheck: Int64 = 0
            while true {
                try cancellation.check()
                guard let data = try input.read(upToCount: 262144), !data.isEmpty else { break }
                if size >= nextSpaceCheck {
                    try TransferStorage.requireSpace(Int64(data.count), at: directory)
                    nextSpaceCheck = size + 16 * 1024 * 1024
                }
                try output.write(contentsOf: data); hash.update(data: data); size += Int64(data.count)
            }
            try cancellation.check()
            let name = String(source.lastPathComponent.map { $0.isNewline || $0.asciiValue == 0 ? "_" : $0 })
            guard (1...1024).contains(name.utf8.count) else { throw TransferError.message("File name is too long.") }
            return OutgoingFile(url: destination, name: name, size: size,
                                sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}

enum TransferStorage {
    static func requireSpace(_ bytes: Int64, at directory: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        if let free = attributes[.systemFreeSize] as? NSNumber,
           free.int64Value < bytes + 16 * 1024 * 1024 {
            throw TransferError.message("Not enough free storage. Free some space and try again.")
        }
    }
}

struct UploadReceipt: Decodable {
    let id: String
    let state: String
    let bytes: Int64
    let size: Int64
    let sha256: String
    let error: String?

    func verifies(_ file: OutgoingFile, id expectedID: String) -> Bool {
        id == expectedID && state == "complete" && bytes == file.size && size == file.size && sha256 == file.sha256
    }
}

enum BoundedResponse {
    static func read(session: URLSession, request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel(); throw TransferError.message("Device response exceeds the supported size.")
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else { throw TransferError.message("Device response exceeds the supported size.") }
                data.append(byte)
            }
        } catch { bytes.task.cancel(); throw error }
        return (data, response)
    }
}
