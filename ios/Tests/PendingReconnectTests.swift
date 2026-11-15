import XCTest
import CryptoKit
@testable import NearbyPrototype

@MainActor
final class BackgroundProbe: TransferBackgroundProviding {
    var canContinue = false
    var expire: (() -> Void)?
    var finished: [Bool] = []
    var latestBytes: Int64 = 0
    func begin(total:Int64,completed:Int64,sending:Bool,expire:@escaping () -> Void,state:@escaping (String)->Void) {
        canContinue=true; self.expire=expire; latestBytes=completed
        state("Background transfer enabled")
    }
    func update(completed:Int64,total:Int64) { latestBytes=completed }
    func finish(success:Bool) { canContinue=false; finished.append(success) }
    func expireNow() { canContinue=false; expire?() }
}

@MainActor
final class PendingReconnectTests: XCTestCase {
    func testSystemProgressReservesSuccessUntilVerificationAndBoundsByteCounts() {
        XCTAssertEqual(ContinuedTransfer.workUnits(completed:0,total:100),0)
        XCTAssertEqual(ContinuedTransfer.workUnits(completed:50,total:100),4950)
        XCTAssertEqual(ContinuedTransfer.workUnits(completed:100,total:100),9900)
        XCTAssertEqual(ContinuedTransfer.workUnits(completed:Int64.max,total:100),9900)
        XCTAssertEqual(ContinuedTransfer.workUnits(completed:-1,total:100),0)
        XCTAssertEqual(ContinuedTransfer.workUnits(completed:0,total:0),0)
    }
    private func bytes() -> Data { Data((0..<(3*1024*1024+17)).map { UInt8($0 % 251) }) }
    private func fixture(token: String = "e") throws -> (Pairing,Manifest,Data) {
        let certificate = try Data(contentsOf:XCTUnwrap(Bundle(for:Self.self).url(forResource:"localhost",withExtension:"der")))
        let pin=SHA256.hash(data:certificate).map { String(format:"%02x",$0) }.joined()
        let data=bytes()
        let hash=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        // Test-only loopback pairing supplied by the injected vault; production
        // scanned/cached pairing validation still rejects loopback addresses.
        let pairing=Pairing(v:1,ssid:"test-hotspot",password:"temporary-password",hosts:["127.0.0.1"],port:19443,token:String(repeating:token,count:64),certificateSHA256:pin)
        return (pairing,Manifest(name:"resumed.bin",size:Int64(data.count),sha256:hash,diagnostics:nil,supportsResume:true),data)
    }
    private func prepare(_ pairing: Pairing,_ file: Manifest,_ bytes: Data) throws -> (URL,MemoryPairingVault,PendingDownloadStore) {
        let checkpoint=try DownloadCheckpoint(pin:pairing.certificateSHA256,manifest:file)
        checkpoint.discard()
        let newCheckpoint=try DownloadCheckpoint(pin:pairing.certificateSHA256,manifest:file)
        let chunk=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.prefix(1024*1024).write(to:chunk)
        defer { try? FileManager.default.removeItem(at:chunk) }
        try newCheckpoint.append(chunk,cancellation:TransferCancellation())
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault=MemoryPairingVault()
        let store=try PendingDownloadStore(directory:directory,vault:vault)
        try store.remember(pairing,manifest:file)
        return (directory,vault,store)
    }
    private func cleanup(_ directory: URL,_ pairing: Pairing,_ file: Manifest,_ model: TransferModel? = nil) {
        let received = model?.received
        model?.disconnect()
        if let received { try? FileManager.default.removeItem(at:received) }
        (try? DownloadCheckpoint(pin:pairing.certificateSHA256,manifest:file))?.discard()
        try? FileManager.default.removeItem(at:directory)
    }
    func testRememberedReconnectUsesSavedFileWithoutScanningAndCompletesFromCheckpoint() async throws {
        let (pairing,file,data)=try fixture()
        let (directory,_,store)=try prepare(pairing,file,data)
        let model=TransferModel(pendingStore:store)
        defer { cleanup(directory,pairing,file,model) }
        XCTAssertEqual(model.pendingDownloads.first?.savedBytes,1024*1024)
        let item=try XCTUnwrap(model.pendingDownloads.first?.download)
        await model.resumePending(item)
        let received=try XCTUnwrap(model.received)
        defer { try? FileManager.default.removeItem(at:received) }
        XCTAssertEqual(try Data(contentsOf:received),data)
        XCTAssertTrue(model.diagnosticReport.contains("Bytes reused from checkpoint: 1048576"))
        XCTAssertTrue(model.pendingDownloads.isEmpty)
    }
    func testDisconnectClearsCredentialsButKeepsProgressAndScanShortcut() async throws {
        let (pairing,file,data)=try fixture()
        let (directory,vault,store)=try prepare(pairing,file,data)
        let model=TransferModel(pendingStore:store)
        defer { cleanup(directory,pairing,file,model) }
        model.pairing=pairing; model.manifest=file
        model.disconnect()
        XCTAssertNil(model.pairing); XCTAssertTrue(vault.values.isEmpty)
        XCTAssertEqual(model.pendingDownloads.first?.savedBytes,1024*1024)
        await model.resumePending(try XCTUnwrap(model.pendingDownloads.first?.download))
        XCTAssertTrue(model.requestedResumeScan); XCTAssertNil(model.received); XCTAssertFalse(model.busy)
        XCTAssertEqual(DownloadCheckpoint.savedOffset(pin:pairing.certificateSHA256,manifest:file),1024*1024)
    }
    func testReconnectDoesNotStartDifferentOfferedFile() async throws {
        let (pairing,file,data)=try fixture(token:"f")
        let (directory,_,store)=try prepare(pairing,file,data)
        let model=TransferModel(pendingStore:store)
        defer { cleanup(directory,pairing,file,model) }
        await model.resumePending(try XCTUnwrap(model.pendingDownloads.first?.download))
        XCTAssertNil(model.received)
        XCTAssertTrue(model.status.contains("different file"))
        XCTAssertEqual(DownloadCheckpoint.savedOffset(pin:pairing.certificateSHA256,manifest:file),1024*1024)
    }
    func testLostSavedBytesAreNotSilentlyReplacedByAFullDownload() async throws {
        let (pairing,file,data)=try fixture()
        let (directory,_,store)=try prepare(pairing,file,data)
        let model=TransferModel(pendingStore:store)
        defer { cleanup(directory,pairing,file,model) }
        let item=try XCTUnwrap(model.pendingDownloads.first?.download)
        (try DownloadCheckpoint(pin:pairing.certificateSHA256,manifest:file)).discard()
        await model.resumePending(item)
        XCTAssertNil(model.received)
        XCTAssertTrue(model.status.contains("could not be restored"))
    }
    func testBackgroundPauseKeepsDownloadShortcutAndCanReconnect() async throws {
        let (pairing,file,data)=try fixture(token:"d")
        let (directory,_,store)=try prepare(pairing,file,data)
        let model=TransferModel(pendingStore:store)
        defer { cleanup(directory,pairing,file,model) }
        model.pairing=pairing
        await model.connect(joinNetwork:false)
        let transfer=Task { await model.receive() }
        let deadline=Date().addingTimeInterval(15)
        while model.received == nil && model.progress <= Double(1024*1024)/Double(file.size) && Date() < deadline {
            try await Task.sleep(nanoseconds:10_000_000)
        }
        XCTAssertTrue(model.busy)
        model.pauseForBackground()
        await transfer.value
        XCTAssertNil(model.received); XCTAssertFalse(model.busy)
        XCTAssertEqual(model.pendingDownloads.first?.savedBytes,1024*1024)
        await model.resumePending(try XCTUnwrap(model.pendingDownloads.first?.download))
        let received=try XCTUnwrap(model.received)
        defer { try? FileManager.default.removeItem(at:received) }
        XCTAssertEqual(try Data(contentsOf:received),data)
    }
    func testGrantedBackgroundExecutionContinuesThroughHomeAndVerifies() async throws {
        let (pairing,file,data)=try fixture(token:"d")
        let (directory,_,store)=try prepare(pairing,file,data)
        let background=BackgroundProbe()
        let model=TransferModel(pendingStore:store,background:background)
        defer { cleanup(directory,pairing,file,model) }
        model.pairing=pairing; await model.connect(joinNetwork:false)
        let transfer=Task { await model.receive() }
        let deadline=Date().addingTimeInterval(15)
        while model.progress <= Double(1024*1024)/Double(file.size) && Date()<deadline {
            try await Task.sleep(nanoseconds:10_000_000)
        }
        XCTAssertTrue(model.busy); XCTAssertTrue(background.canContinue)
        model.pauseForBackground()
        await transfer.value
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(model.received)),data)
        XCTAssertEqual(background.finished.last,true)
        XCTAssertGreaterThan(background.latestBytes,1024*1024)
    }
    func testSystemBackgroundCancellationKeepsPiecesAndOldExpiryCannotStopNewResume() async throws {
        let (pairing,file,data)=try fixture(token:"d")
        let (directory,_,store)=try prepare(pairing,file,data)
        let background=BackgroundProbe()
        let model=TransferModel(pendingStore:store,background:background)
        defer { cleanup(directory,pairing,file,model) }
        model.pairing=pairing; await model.connect(joinNetwork:false)
        let first=Task { await model.receive() }
        let deadline=Date().addingTimeInterval(15)
        while model.progress <= Double(1024*1024)/Double(file.size) && Date()<deadline {
            try await Task.sleep(nanoseconds:10_000_000)
        }
        let oldExpiry=try XCTUnwrap(background.expire)
        background.expireNow(); await first.value
        XCTAssertNil(model.received)
        XCTAssertEqual(model.pendingDownloads.first?.savedBytes,1024*1024)
        XCTAssertEqual(background.finished.last,false)
        let item=try XCTUnwrap(model.pendingDownloads.first?.download)
        let second=Task { await model.resumePending(item) }
        while !background.canContinue && Date()<deadline { try await Task.sleep(nanoseconds:10_000_000) }
        oldExpiry() // A delayed callback from the previous task must not cancel this one.
        await second.value
        XCTAssertEqual(try Data(contentsOf:XCTUnwrap(model.received)),data)
        XCTAssertEqual(background.finished.last,true)
    }
}
