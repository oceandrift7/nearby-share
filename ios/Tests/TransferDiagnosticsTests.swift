import XCTest
import NetworkExtension
@testable import NearbyPrototype

final class TransferDiagnosticsTests: XCTestCase {
    private func profile(_ entitlements: [String: Any]) throws -> Data {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements, "TeamName": "private-account-name"], format: .xml, options: 0)
        return Data([0x30, 0x82, 0xff]) + xml + Data([0, 1, 2])
    }

    func testProfileWithCapabilityIsReportedWithoutAccountData() throws {
        let status = HotspotProfileStatus.inspect(try profile(["com.apple.developer.networking.HotspotConfiguration": true]))
        XCTAssertEqual(status, .present)
        XCTAssertFalse(status.rawValue.contains("private-account-name"))
    }

    func testMissingOrFalseCapabilityIsIdentified() throws {
        XCTAssertEqual(HotspotProfileStatus.inspect(try profile([:])), .missing)
        XCTAssertEqual(HotspotProfileStatus.inspect(try profile(["com.apple.developer.networking.HotspotConfiguration": false])), .missing)
    }

    func testUnreadableProfileRemainsUnknown() {
        for data in [Data(), Data("<?xml malformed </plist>".utf8), Data(repeating: 0, count: 4_194_305)] {
            XCTAssertEqual(HotspotProfileStatus.inspect(data), .unknown)
        }
    }

    func testNormalJoinHasBoundedLifetime() {
        let pairing = Pairing(v: 1, ssid: "temporary-test", password: "test-password", hosts: ["192.168.43.1"], port: 9443,
                              token: String(repeating: "a", count: 64), certificateSHA256: String(repeating: "b", count: 64))
        let config = JoinSettings.configuration(for: pairing)
        XCTAssertFalse(config.joinOnce)
        XCTAssertEqual(config.lifeTimeInDays, 1)
        XCTAssertEqual(config.ssid, pairing.ssid)
    }

    func testJoinRecoveryDoesNotIgnoreUserDenialOrInvalidCredentials() {
        XCTAssertTrue(JoinSettings.shouldInspectAfterFailure(NSError(domain: NEHotspotConfigurationErrorDomain, code: 8)))
        XCTAssertTrue(JoinSettings.shouldInspectAfterFailure(NSError(domain: NEHotspotConfigurationErrorDomain, code: NEHotspotConfigurationError.alreadyAssociated.rawValue)))
        for code in [NEHotspotConfigurationError.userDenied.rawValue, NEHotspotConfigurationError.invalidWPAPassphrase.rawValue] {
            XCTAssertFalse(JoinSettings.shouldInspectAfterFailure(NSError(domain: NEHotspotConfigurationErrorDomain, code: code)))
        }
        XCTAssertFalse(JoinSettings.shouldInspectAfterFailure(NSError(domain: NSURLErrorDomain, code: 8)))
    }

    func testOldSenderManifestStillDecodes() throws {
        let data = Data("{\"name\":\"photo.jpg\",\"size\":42,\"sha256\":\"abc\"}".utf8)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        XCTAssertEqual(manifest.size, 42)
        XCTAssertNil(manifest.diagnostics)
    }

    func testAllowedBandsDoNotClaimActualChannelOrSpeed() {
        let diagnostics = SenderDiagnostics(appVersion: "0.1.3", model: "test-model", androidAPI: 31, hotspotBandMask: 3, supports5GHz: true)
        XCTAssertTrue(diagnostics.summary.contains("Hotspot allowed bands: 2.4 GHz, 5 GHz"))
        XCTAssertTrue(diagnostics.summary.contains("Actual channel and link speed: not measured"))
        let old = SenderDiagnostics(appVersion: "0.1.3", model: "test", androidAPI: 29, hotspotBandMask: nil, supports5GHz: false)
        XCTAssertTrue(old.summary.contains("unavailable on this Android version"))
    }

    func testMissingOrInvalidTimingIsNotReportedAsZero() {
        XCTAssertNil(TransferTiming.interval(nil, Date()))
        XCTAssertNil(TransferTiming.interval(Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(TransferTiming.interval(Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 3)), 2)
        XCTAssertTrue(TransferTiming().summary.contains("TLS handshake: not recorded"))
    }
}
