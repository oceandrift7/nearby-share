import XCTest
import Security
@testable import NearbyPrototype

final class MemoryPairingVault: PairingVault {
    var values: [String: Pairing] = [:]
    var canSave = true
    func save(_ pairing: Pairing,id:String) -> Bool { if !canSave { return false }; values[id]=pairing; return true }
    func load(id:String) -> Pairing? { values[id] }
    func remove(id:String) { values[id]=nil }
}

final class PendingDownloadStoreTests: XCTestCase {
    private func pairing() -> Pairing {
        Pairing(v:1,ssid:"test-hotspot",password:"temporary-password",hosts:["192.168.43.1"],port:9443,token:String(repeating:"a",count:64),certificateSHA256:String(repeating:"b",count:64))
    }
    private func file(_ number: Int = 1) -> Manifest {
        Manifest(name:"file\(number).bin",size:1024,sha256:String(repeating:String(number % 10),count:64),diagnostics:nil,supportsResume:true)
    }
    private func withStore(_ body:(URL,MemoryPairingVault,PendingDownloadStore) throws -> Void) throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let vault=MemoryPairingVault(); try body(directory,vault,PendingDownloadStore(directory:directory,vault:vault))
    }
    func testRememberedFileSurvivesReloadWithoutNetworkSecretsInRegistry() throws {
        try withStore { directory,vault,store in
            XCTAssertTrue(try store.remember(pairing(),manifest:file()))
            let restored=try PendingDownloadStore(directory:directory,vault:vault)
            let item=try XCTUnwrap(restored.all().first)
            XCTAssertEqual(item.name,"file1.bin"); XCTAssertEqual(restored.pairing(for:item)?.token,pairing().token)
            let text=try String(contentsOf:directory.appendingPathComponent("downloads.json"),encoding:.utf8)
            XCTAssertFalse(text.contains(pairing().password)); XCTAssertFalse(text.contains(pairing().token)); XCTAssertFalse(text.contains(pairing().ssid))
        }
    }
    func testClearingPairingKeepsFileEntryButRemovesReconnectCredential() throws {
        try withStore { _,vault,store in
            try store.remember(pairing(),manifest:file())
            let item=try XCTUnwrap(store.all().first)
            store.forgetPairing(pin:pairing().certificateSHA256)
            XCTAssertEqual(store.all().count,1); XCTAssertNil(store.pairing(for:item)); XCTAssertTrue(vault.values.isEmpty)
        }
    }
    func testNoCredentialPermissionStillRemembersFileForScanning() throws {
        try withStore { _,vault,store in
            vault.canSave=false
            XCTAssertFalse(try store.remember(pairing(),manifest:file()))
            XCTAssertEqual(store.all().count,1); XCTAssertNil(store.pairing(for:store.all()[0]))
        }
    }
    func testHistoryIsBoundedDeduplicatedAndRemovedCredentialsAreForgotten() throws {
        try withStore { _,vault,store in
            for value in 1...9 { try store.remember(pairing(),manifest:file(value)) }
            XCTAssertEqual(store.all().count,8); XCTAssertEqual(vault.values.count,8)
            try store.remember(pairing(),manifest:file(9)); XCTAssertEqual(store.all().count,8)
            try store.remove(store.all()[0]); XCTAssertEqual(store.all().count,7); XCTAssertEqual(vault.values.count,7)
            try store.removeAll(); XCTAssertTrue(store.all().isEmpty); XCTAssertTrue(vault.values.isEmpty)
        }
    }
    func testRememberedFileCannotAutomaticallyAcceptAnotherFileOrSender() throws {
        try withStore { _,_,store in
            let first=pairing(); try store.remember(first,manifest:file())
            let item=store.all()[0]
            XCTAssertTrue(item.matches(first,file()))
            XCTAssertFalse(item.matches(first,file(2)))
            let other=Pairing(v:1,ssid:first.ssid,password:first.password,hosts:first.hosts,port:first.port,token:first.token,certificateSHA256:String(repeating:"c",count:64))
            XCTAssertFalse(item.matches(other,file()))
        }
    }
    func testActualKeychainRoundTripAndDeletion() throws {
        let vault=KeychainPairingVault(service:"org.nearbyshare.tests.\(UUID().uuidString)")
        let id=UUID().uuidString; defer { vault.remove(id:id) }
        XCTAssertEqual(vault.saveStatus(pairing(),id:id),errSecSuccess,"Standard app Keychain storage failed")
        XCTAssertEqual(vault.load(id:id)?.token,pairing().token)
        let old=pairing()
        let fresh=Pairing(v:old.v,ssid:old.ssid,password:old.password,hosts:old.hosts,port:old.port,token:String(repeating:"c",count:64),certificateSHA256:old.certificateSHA256)
        XCTAssertTrue(vault.save(fresh,id:id)); XCTAssertEqual(vault.load(id:id)?.token,fresh.token)
        vault.remove(id:id); XCTAssertNil(vault.load(id:id))
    }
}
