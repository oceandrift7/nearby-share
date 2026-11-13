import XCTest
@testable import NearbyPrototype

final class PairingSecurityTests: XCTestCase {
    private func code(hosts: [String] = ["192.168.43.1"], version: Int = 1, pin: String? = nil) throws -> String {
        let values: [String: Any] = [
            "v": version, "ssid": "test-hotspot", "password": "temporary-password",
            "hosts": hosts, "port": 9443, "token": String(repeating: "a", count: 64),
            "certificateSHA256": pin ?? String(repeating: "b", count: 64)
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }

    func testAcceptsHotspotAddressWithoutAssumingOneSubnet() throws {
        for host in ["192.168.43.1", "192.168.50.1", "10.0.0.1", "172.16.0.1"] {
            XCTAssertNoThrow(try Pairing.parse(code(hosts: [host])))
        }
    }

    func testQRDoesNotAuthorizePublicLoopbackOrDNSDestinations() throws {
        for host in ["127.0.0.1", "8.8.8.8", "example.com", "192.168.1.1.example.com", "192.168.1.256", "::1", "172.32.0.1", "169.254.1.1"] {
            XCTAssertThrowsError(try Pairing.parse(code(hosts: [host])), host)
        }
        XCTAssertThrowsError(try Pairing.parse(code(hosts: ["192.168.43.1", "8.8.8.8"])))
    }

    func testRejectsUnsupportedVersionAndMalformedCertificatePin() throws {
        XCTAssertThrowsError(try Pairing.parse(code(version: 2)))
        XCTAssertThrowsError(try Pairing.parse(code(pin: "accept-any-certificate")))
        XCTAssertThrowsError(try Pairing.parse(code(pin: String(repeating: "g", count: 64))))
    }

    func testRejectsEmptyOrExcessiveHostListsAndOversizedCodes() throws {
        XCTAssertThrowsError(try Pairing.parse(code(hosts: [])))
        XCTAssertThrowsError(try Pairing.parse(code(hosts: Array(repeating: "192.168.43.1", count: 17))))
        XCTAssertThrowsError(try Pairing.parse(String(repeating: " ", count: 4097)))
    }
}
