package org.nearbyshare.prototype

import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.security.MessageDigest

class RangeDownloadTest {
    private fun withSender(block: (ReceiveInboxTest.Fixture, ByteArray, String) -> Unit) {
        val bytes = ByteArray(2 * 1024 * 1024 + 17) { (65 + it % 26).toByte() }
        val file = File.createTempFile("range-test", ".bin", InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)
        file.writeBytes(bytes)
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
        val manifest = JSONObject().put("name", "test.bin").put("size", bytes.size).put("sha256", hash)
        try { ReceiveInboxTest.Fixture(tls = true, outgoing = file, outgoingManifest = manifest).use { block(it, bytes, hash) } }
        finally { file.delete() }
    }

    @Test fun pinnedRangesReconstructExactFileAndLegacyDownloadStillWorks() = withSender { f, bytes, hash ->
        assertTrue(JSONObject(f.request("GET", "/manifest").second).getBoolean("supportsResume"))
        val collected = java.io.ByteArrayOutputStream()
        var offset = 0
        while (offset < bytes.size) {
            val end = minOf(offset + 1024 * 1024, bytes.size) - 1
            val response = f.request("GET", "/file", extraHeaders = "Range: bytes=$offset-$end\r\nIf-Match: \"$hash\"\r\n")
            assertEquals(206, response.first)
            collected.write(response.second.toByteArray(Charsets.UTF_8))
            offset = end + 1
        }
        assertArrayEquals(bytes, collected.toByteArray())
        assertArrayEquals(bytes, f.request("GET", "/file").second.toByteArray(Charsets.UTF_8))
    }

    @Test fun rangesRequireCurrentAuthorizationAndExactFileIdentity() = withSender { f, _, hash ->
        assertEquals(403, f.request("GET", "/file", token = "expired", extraHeaders = "Range: bytes=0-10\r\nIf-Match: \"$hash\"\r\n").first)
        assertEquals(412, f.request("GET", "/file", extraHeaders = "Range: bytes=0-10\r\n").first)
        assertEquals(412, f.request("GET", "/file", extraHeaders = "Range: bytes=0-10\r\nIf-Match: \"wrong-file\"\r\n").first)
        assertEquals(206, f.request("GET", "/file", extraHeaders = "Range: bytes=0-10\r\nIf-Match: \"$hash\"\r\n").first)
    }

    @Test fun invalidOverflowAndMultipartRangesAreRejected() = withSender { f, bytes, hash ->
        for (range in listOf("bytes=-1-10", "bytes=10-0", "bytes=0-${bytes.size}", "bytes=${bytes.size}-${bytes.size}",
                "bytes=0-1,3-4", "bytes=0-", "bytes=9999999999999999999999999-99999999999999999999999999", "items=0-10")) {
            assertEquals(range, 416, f.request("GET", "/file", extraHeaders = "Range: $range\r\nIf-Match: \"$hash\"\r\n").first)
        }
    }
}
