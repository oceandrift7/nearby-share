package org.nearbyshare.prototype

// ZXing's Wi-Fi format is understood by the iPhone system Camera. This code
// joins the network only; the separate Nearby QR carries the TLS pin and token.
object WifiQr {
    fun encode(ssid: String, password: String): String {
        fun escape(value: String) = buildString {
            for (character in value) {
                if (character in "\\;,:\"") append('\\')
                append(character)
            }
        }
        return "WIFI:T:WPA;S:${escape(ssid)};P:${escape(password)};;"
    }
}
