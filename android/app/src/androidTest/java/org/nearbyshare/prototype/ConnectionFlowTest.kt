package org.nearbyshare.prototype

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.zxing.*
import com.google.zxing.client.result.ResultParser
import com.google.zxing.client.result.WifiParsedResult
import com.google.zxing.common.HybridBinarizer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.File
import java.net.Socket
import org.json.JSONObject
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ConnectionFlowTest {
    @Test fun actualServerPreservesFileAndAuthorizesPerDownloadMeasurements() {
        val file = File.createTempFile("read-test", ".bin", InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
        val expected = ByteArray(300_001) { (it % 251).toByte() }
        file.writeBytes(expected)
        val server = SharedFileServer(0, "test-token", file, JSONObject()) {}
        // Raw loopback HTTP isolates the production response/stream lifecycle.
        // TLS + pin verification run separately in TlsHandshakeTest on both APIs.
        fun request(path: String, token: String = "test-token", id: String? = null, method: String = "GET"): Pair<String, ByteArray> {
            return Socket("127.0.0.1", server.listeningPort).use { socket ->
                socket.soTimeout = 5000
                val extra = if (id == null) "" else "X-Nearby-Transfer-ID: $id\r\n"
                socket.getOutputStream().write(("$method $path HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer $token\r\n${extra}Connection: close\r\n\r\n").toByteArray())
                val response = socket.getInputStream().readBytes()
                val boundary = (0 until response.size - 3).first {
                    response[it] == 13.toByte() && response[it + 1] == 10.toByte() && response[it + 2] == 13.toByte() && response[it + 3] == 10.toByte()
                }
                String(response, 0, boundary, Charsets.US_ASCII) to response.copyOfRange(boundary + 4, response.size)
            }
        }
        try {
            server.start(5000, true)
            val id = UUID.randomUUID().toString()
            assertTrue(request("/transfer-stats?id=$id").first.startsWith("HTTP/1.1 404"))
            assertTrue(request("/file", token = "wrong", id = id).first.startsWith("HTTP/1.1 403"))
            val fileResponse = request("/file", id = id)
            assertTrue(fileResponse.first.startsWith("HTTP/1.1 200"))
            assertArrayEquals(expected, fileResponse.second)
            assertTrue(request("/transfer-stats?id=$id", token = "wrong").first.startsWith("HTTP/1.1 403"))
            assertTrue(request("/transfer-stats?id=$id", method = "POST").first.startsWith("HTTP/1.1 403"))
            val report = request("/transfer-stats?id=$id")
            assertTrue(report.first.startsWith("HTTP/1.1 200"))
            assertTrue(report.first.contains("Cache-Control: no-store", ignoreCase = true))
            val stats = JSONObject(String(report.second, Charsets.UTF_8))
            assertEquals(expected.size.toLong(), stats.getLong("bytes"))
            assertTrue(stats.getLong("calls") > 0)
            assertTrue(stats.getDouble("readSeconds") >= 0)
            assertArrayEquals(expected, request("/file").second) // Older receiver sends no ID.
            assertTrue(request("/transfer-stats?id=${UUID.randomUUID()}").first.startsWith("HTTP/1.1 404"))
        } finally { server.stop(); file.delete() }
    }

    @Test fun wifiCodeRoundTripsThroughQrDecoderWithEscapedCredentials() {
        val ssid = "Android;Share,\\test:\""
        val password = "pass;word,\\12:\"34"
        val payload = WifiQr.encode(ssid, password)
        val matrix = MultiFormatWriter().encode(payload, BarcodeFormat.QR_CODE, 800, 800)
        val pixels = IntArray(800 * 800) { if (matrix[it % 800, it / 800]) 0xff000000.toInt() else 0xffffffff.toInt() }
        val decoded = MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(800, 800, pixels))))
        val wifi = ResultParser.parseResult(decoded) as WifiParsedResult
        assertEquals("WPA", wifi.networkEncryption)
        assertEquals(ssid, wifi.ssid)
        assertEquals(password, wifi.password)
        assertFalse(payload.contains("certificateSHA256"))
        assertFalse(payload.contains("token"))
    }

    @Test fun measuredStreamPreservesBytesCountsPartialReadsAndReportsOnlyOnce() {
        val original = ByteArray(700_001) { (it % 251).toByte() }
        var completions = 0
        var stats: SenderReadStats? = null
        val input = TimedSnapshotInputStream(ByteArrayInputStream(original).buffered(262144)) { stats = it; completions++ }
        assertEquals(original[0].toInt() and 255, input.read())
        val rest = input.readBytes()
        assertArrayEquals(original.copyOfRange(1, original.size), rest)
        assertNull(stats)
        input.close(); input.close()
        assertEquals(1, completions)
        assertEquals(original.size.toLong(), stats!!.bytes)
        assertTrue(stats!!.calls > 1)
        assertTrue(stats!!.nanoseconds >= 0)
    }

    @Test fun cancelledStreamReportsOnlyReadBytesAndRecordsAreBoundedAndIsolated() {
        val records = SenderReadReports()
        val ids = (0..9).map { UUID.randomUUID().toString() }
        ids.forEachIndexed { index, id ->
            TimedSnapshotInputStream(ByteArrayInputStream(ByteArray(1000))) { records.put(id, it) }.use {
                it.read(ByteArray(index + 1))
            }
        }
        assertNull(records.get(ids[0])); assertNull(records.get(ids[1]))
        for (index in 2..9) assertEquals((index + 1).toLong(), records.get(ids[index])!!.bytes)
        records.put("invalid", SenderReadStats(1000, 1, 0))
        assertNull(records.get("invalid"))
        assertFalse(records.validID(null))
        assertFalse(records.validID("a".repeat(100_000)))
    }
}
