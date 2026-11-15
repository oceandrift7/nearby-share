import Foundation
import Security
import CryptoKit

protocol PairingVault {
    func save(_ pairing: Pairing, id: String) -> Bool
    func load(id: String) -> Pairing?
    func remove(id: String)
}

struct KeychainPairingVault: PairingVault {
    let service: String
    init(service: String = "org.nearbyshare.pending-downloads") { self.service = service }
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
         kSecAttrAccount as String:id, kSecAttrSynchronizable as String:false]
    }
    func save(_ pairing: Pairing, id: String) -> Bool {
        saveStatus(pairing,id:id) == errSecSuccess
    }
    func saveStatus(_ pairing: Pairing, id: String) -> OSStatus {
        guard let data = try? JSONEncoder().encode(pairing), data.count <= 4096 else { return errSecParam }
        let attributes: [String: Any] = [kSecValueData as String:data,
            kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return updated }
        guard updated == errSecItemNotFound else { return updated }
        var value = query(id); attributes.forEach { value[$0.key] = $0.value }
        return SecItemAdd(value as CFDictionary, nil)
    }
    func load(id: String) -> Pairing? {
        var value = query(id); value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(value as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 4096 else { return nil }
        return try? Pairing.parse(String(decoding:data,as:UTF8.self))
    }
    func remove(id: String) { SecItemDelete(query(id) as CFDictionary) }
}

struct PendingDownload: Codable, Identifiable {
    let name: String
    let size: Int64
    let sha256: String
    let certificateSHA256: String
    var id: String { DownloadCheckpoint.identity(pin: certificateSHA256, manifest: manifest) }
    var manifest: Manifest { Manifest(name:name, size:size, sha256:sha256, diagnostics:nil, supportsResume:true) }
    func matches(_ pairing: Pairing, _ manifest: Manifest) -> Bool {
        certificateSHA256 == pairing.certificateSHA256 && sha256 == manifest.sha256 && size == manifest.size && manifest.mode != "receive"
    }
    var valid: Bool {
        (1...1024).contains(name.utf8.count) && (0...1_099_511_627_776).contains(size) &&
        [sha256,certificateSHA256].allSatisfy { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }
    }
}

struct PendingDownloadRow: Identifiable {
    let download: PendingDownload
    let savedBytes: Int64
    let canReconnect: Bool
    var id: String { download.id }
}

/// Names/identity in private, backup-excluded storage; network secrets only in Keychain.
final class PendingDownloadStore {
    private let directory: URL
    private let file: URL
    private let vault: PairingVault
    init(directory: URL? = nil, vault: PairingVault = KeychainPairingVault()) throws {
        var root = try directory ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("PendingDownloads",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try root.setResourceValues(values)
        self.directory = root; file = root.appendingPathComponent("downloads.json"); self.vault = vault
    }
    func all() -> [PendingDownload] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue,
              size <= 65536, let data = try? Data(contentsOf:file), let records = try? JSONDecoder().decode([PendingDownload].self,from:data),
              records.count <= 8, records.allSatisfy(\.valid), Set(records.map(\.id)).count == records.count else { return [] }
        return records
    }
    private func write(_ records: [PendingDownload]) throws {
        try JSONEncoder().encode(records).write(to:file,options:.atomic)
    }
    @discardableResult func remember(_ pairing: Pairing, manifest: Manifest) throws -> Bool {
        let item = PendingDownload(name:manifest.name,size:manifest.size,sha256:manifest.sha256,certificateSHA256:pairing.certificateSHA256)
        guard item.valid, manifest.supportsResume == true, manifest.mode != "receive" else { throw TransferError.message("Invalid remembered download.") }
        let previous = all()
        let next = Array(([item] + previous.filter { $0.id != item.id }).prefix(8))
        try write(next)
        for old in previous where !next.contains(where: { $0.id == old.id }) { vault.remove(id:old.id) }
        return vault.save(pairing,id:item.id)
    }
    func pairing(for item: PendingDownload) -> Pairing? {
        guard let pairing = vault.load(id:item.id), item.matches(pairing,item.manifest) else { return nil }
        return pairing
    }
    func forgetPairing(pin: String) {
        for item in all() where item.certificateSHA256 == pin { vault.remove(id:item.id) }
    }
    func remove(_ item: PendingDownload) throws {
        try write(all().filter { $0.id != item.id }); vault.remove(id:item.id)
    }
    func removeAll() throws {
        let old = all(); try write([])
        old.forEach { vault.remove(id:$0.id) }
    }
}
