package org.nearbyshare.prototype

import org.junit.Test
import org.junit.Assert.*
import org.json.JSONObject
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.TimeUnit

class RequestSecurityTest {
    private fun metadata() = JSONObject().put("name", "file.bin").put("size", 0).put("sha256", "0".repeat(64))

    @Test fun coercibleAndMalformedMetadataIsRejectedBeforeOfferingOrWritingFiles() {
        // Reproduce why the old getters were insufficient: both silently change types.
        assertEquals(0L, JSONObject().put("size", 0.9).getLong("size"))
        assertEquals(0L, JSONObject().put("size", "0").getLong("size"))
        assertEquals("123", JSONObject().put("name", 123).getString("name"))
        ReceiveInboxTest.Fixture().use { f ->
            val invalid = mutableListOf<String>()
            for (value in listOf<Any>("0", 0.9, true, JSONObject.NULL, -1, 1_099_511_627_777L))
                invalid.add(metadata().put("size", value).toString())
            for (value in listOf<Any>(123, true, JSONObject.NULL, "", "x".repeat(1025), "x\u0000y"))
                invalid.add(metadata().put("name", value).toString())
            for (value in listOf<Any>(123, true, JSONObject.NULL, "A".repeat(64), "0".repeat(63)))
                invalid.add(metadata().put("sha256", value).toString())
            invalid.addAll(listOf("", "{", "[]", "null", "false", "{\"size\":0}"))
            val random = java.util.Random(713)
            repeat(64) {
                invalid.add(JSONObject().put("unexpected", random.nextLong()).put("size", random.nextDouble()).toString())
            }
            for (body in invalid) {
                assertEquals("Accepted invalid metadata: $body", 400, f.request("POST", "/offer", body.toByteArray()).first)
                assertNull(f.inbox.snapshot())
                assertTrue(f.directory.listFiles().isNullOrEmpty())
            }
            val valid = metadata().put("name", "صورة.jpg").toString().toByteArray()
            assertEquals(200, f.request("POST", "/offer", valid).first)
            assertEquals("waiting", f.inbox.snapshot()!!.state)
        }
    }

    @Test fun oldSessionTokenCannotReadOfferCancelOrUploadInNewSession() {
        ReceiveInboxTest.Fixture(sessionToken = "new-session-token").use { f ->
            val offered = f.request("POST", "/offer", metadata().toString().toByteArray(), token = "new-session-token")
            assertEquals(200, offered.first)
            val id = JSONObject(offered.second).getString("id")
            for ((method, path) in listOf("GET" to "/manifest", "GET" to "/offer?id=$id", "DELETE" to "/offer?id=$id", "PUT" to "/upload?id=$id", "POST" to "/offer")) {
                assertEquals(403, f.request(method, path, token = "old-session-token", sendBody = false).first)
                assertEquals("waiting", f.inbox.snapshot()!!.state)
                assertTrue(f.directory.listFiles().isNullOrEmpty())
            }
        }
    }

    @Test fun chunkedAndMismatchedLengthsCannotStartAnUpload() {
        ReceiveInboxTest.Fixture().use { f ->
            assertEquals(400, f.request("POST", "/offer", sendBody = false, length = 40, extraHeaders = "Transfer-Encoding: chunked\r\n").first)
            val offer = f.request("POST", "/offer", metadata().toString().toByteArray())
            val id = JSONObject(offer.second).getString("id")
            f.inbox.decide(id, true)
            assertEquals(400, f.request("PUT", "/upload?id=$id", sendBody = false, length = 1).first)
            assertEquals(400, f.request("PUT", "/upload?id=$id", sendBody = false, extraHeaders = "Transfer-Encoding: chunked\r\n").first)
            assertEquals("accepted", f.inbox.snapshot()!!.state)
            assertTrue(f.directory.listFiles().isNullOrEmpty())
        }
    }

    @Test fun idleConnectionsAreCappedAndServerRecoversAfterTheyClose() {
        ReceiveInboxTest.Fixture().use { f ->
            val sockets = mutableListOf<Socket>()
            fun awaitCount(count: Int) {
                val end = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                while (f.server.connections.activeCount != count && System.nanoTime() < end) Thread.sleep(10)
                assertEquals(count, f.server.connections.activeCount)
            }
            try {
                repeat(8) { sockets.add(Socket("127.0.0.1", f.server.listeningPort)) }
                awaitCount(8)
                Socket("127.0.0.1", f.server.listeningPort).use { extra ->
                    extra.soTimeout = 3000
                    try { assertEquals(-1, extra.inputStream.read()) } catch (_: SocketException) { /* Reset is a valid refusal. */ }
                }
                assertEquals(8, f.server.connections.activeCount)
                sockets.forEach { it.close() }; awaitCount(0)
                assertEquals(200, f.request("GET", "/manifest").first)
            } finally { sockets.forEach { it.close() } }
        }
    }
}
