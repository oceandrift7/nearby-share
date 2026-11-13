import XCTest
import NetworkExtension
@testable import NearbyPrototype

final class ConnectionDiagnosticsTests: XCTestCase {
    func testInternalJoinErrorIncludesCodeAndManualRecoveryWithoutClaimingRootCause() {
        let error = NSError(domain: NEHotspotConfigurationErrorDomain, code: 8,
                            userInfo: [NSLocalizedDescriptionKey: "internal error."])
        let text = ConnectionDiagnostics.describe(error, stage: "Wi-Fi join")
        XCTAssertTrue(text.contains("Wi-Fi join failed"))
        XCTAssertTrue(text.contains("code 8"))
        XCTAssertTrue(text.contains("Settings → Wi-Fi"))
        XCTAssertTrue(text.contains("does not prove a signing issue"))
    }

    func testRequestErrorDoesNotGetMislabelledAsHotspotSigningFailure() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: "Timed out"])
        let text = ConnectionDiagnostics.describe(error, stage: "Sender request")
        XCTAssertTrue(text.contains("Sender request failed"))
        XCTAssertTrue(text.contains("NSURLErrorDomain"))
        XCTAssertFalse(text.contains("provisioning profile"))
    }
}
