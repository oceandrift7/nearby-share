import Foundation
import NetworkExtension

enum HotspotProfileStatus: String {
    case present = "allowed by embedded profile"
    case missing = "missing from embedded profile"
    case unknown = "profile unavailable or unreadable"

    static func installed() -> Self {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .unknown }
        return inspect(data)
    }

    // Diagnostic only. This reads the XML payload in the embedded CMS container;
    // it neither validates its signature nor authorizes any network connection.
    // Never expose account identifiers, device IDs or certificates from the profile.
    static func inspect(_ data: Data) -> Self {
        guard data.count <= 4_194_304,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil),
              let dictionary = plist as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any] else { return .unknown }
        return (entitlements["com.apple.developer.networking.HotspotConfiguration"] as? Bool) == true ? .present : .missing
    }
}

enum JoinSettings {
    static func configuration(for pairing: Pairing) -> NEHotspotConfiguration {
        let configuration = NEHotspotConfiguration(ssid: pairing.ssid, passphrase: pairing.password, isWEP: false)
        configuration.joinOnce = false
        configuration.lifeTimeInDays = 1
        return configuration
    }

    static func shouldInspectAfterFailure(_ error: NSError) -> Bool {
        error.domain == NEHotspotConfigurationErrorDomain &&
            (error.code == NEHotspotConfigurationError.internal.rawValue ||
             error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue)
    }
}

struct SenderDiagnostics: Decodable {
    let appVersion: String
    let model: String
    let androidAPI: Int
    let hotspotBandMask: Int?
    let supports5GHz: Bool

    var summary: String {
        let bands: String
        if let mask = hotspotBandMask {
            let names = [(1, "2.4 GHz"), (2, "5 GHz"), (4, "6 GHz")].filter { mask & $0.0 != 0 }.map { $0.1 }
            bands = names.isEmpty ? "unknown" : names.joined(separator: ", ")
        } else { bands = "unavailable on this Android version" }
        return "Sender: \(model.prefix(80)), Android API \(androidAPI), app \(appVersion.prefix(32))\nHotspot allowed bands: \(bands)\n5 GHz hardware support: \(supports5GHz ? "yes" : "no")\nActual channel and link speed: not measured"
    }
}

struct TransferTiming {
    var firstByte: TimeInterval?
    var body: TimeInterval?
    var tls: TimeInterval?
    var reused = false

    static func interval(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    var summary: String {
        func time(_ value: TimeInterval?) -> String { value.map { String(format: "%.3f s", $0) } ?? "not recorded" }
        return "Request to first byte: \(time(firstByte))\nResponse body: \(time(body))\nTLS handshake: \(time(tls))\nConnection reused: \(reused ? "yes" : "no")"
    }
}
