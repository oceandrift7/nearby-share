package org.nearbyshare.prototype

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import org.json.JSONObject
import java.security.MessageDigest

/** Software-path throughput over pinned TLS loopback, not a Wi-Fi benchmark. */
class TransferBenchmarkTest {
    @Test fun approvedStreamedUploadIsVerifiedAndMeasured() {
        val mib = InstrumentationRegistry.getArguments().getString("benchmarkMiB", "64")!!.toInt()
        require(mib in listOf(8, 64, 256))
        val size = mib.toLong() * 1024 * 1024
        val chunk = ByteArray(262144) { 90 }
        val digest = MessageDigest.getInstance("SHA-256")
        repeat(mib * 4) { digest.update(chunk) }
        val hash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        ReceiveInboxTest.Fixture(tls = true).use { f ->
            val offer = JSONObject().put("name", "benchmark.bin").put("size", size).put("sha256", hash)
            val offered = f.request("POST", "/offer", offer.toString().toByteArray())
            assertEquals(200, offered.first)
            val id = JSONObject(offered.second).getString("id")
            f.inbox.decide(id, true)
            val start = System.nanoTime()
            f.socket().use { socket ->
                socket.soTimeout = 120000
                val output = socket.outputStream
                output.write(("PUT /upload?id=$id HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret\r\nContent-Length: $size\r\nConnection: close\r\n\r\n").toByteArray())
                repeat(mib * 4) { output.write(chunk) }; output.flush()
                val response = socket.inputStream.readBytes().toString(Charsets.UTF_8)
                assertTrue(response.startsWith("HTTP/1.1 200"))
                val receipt = JSONObject(response.substringAfter("\r\n\r\n"))
                assertEquals("complete", receipt.getString("state"))
                assertEquals(hash, receipt.getString("sha256"))
                assertEquals(size, receipt.getLong("bytes"))
            }
            val seconds = (System.nanoTime() - start) / 1e9
            assertEquals(size, f.inbox.snapshot()!!.saved!!.length())
            val report = JSONObject().put("platform", "Android API ${android.os.Build.VERSION.SDK_INT}")
                .put("path", "production Android receive server; pinned TLS loopback")
                .put("bytes", size).put("seconds", seconds).put("MBps", size / seconds / 1e6)
                .put("verified", true).put("includes", "TLS connection, streaming hash, disk save and acknowledgement")
                .put("physicalWiFi", false)
            android.util.Log.i("NEARBY_BENCHMARK", report.toString())
        }
    }
}
