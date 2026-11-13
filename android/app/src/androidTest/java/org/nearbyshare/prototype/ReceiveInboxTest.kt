package org.nearbyshare.prototype

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import java.io.File
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

@RunWith(AndroidJUnit4::class)
class ReceiveInboxTest {
    private class Fixture(val space: () -> Long = { Long.MAX_VALUE }, tls: Boolean = false) : AutoCloseable {
        val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "inbox-test-${java.util.UUID.randomUUID()}")
        val inbox = ReceiveInbox(directory, space)
        val server = SharedFileServer(0, "secret", null, JSONObject().put("mode", "receive"), inbox) {}
        private var ssl: SSLContext? = null
        init {
            if (tls) {
                val identity = LocalTlsIdentity.create()
                server.makeSecure(identity.context.serverSocketFactory, LocalTlsIdentity.protocols)
                val trust = object : X509TrustManager {
                    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
                    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) { throw CertificateException() }
                    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                        if (chain.isNullOrEmpty() || !MessageDigest.isEqual(chain[0].encoded, identity.certificate.encoded)) throw CertificateException()
                    }
                }
                ssl = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
            }
            server.start(3000, true)
        }
        fun request(method: String, path: String, body: ByteArray = byteArrayOf(), token: String = "secret", length: Int = body.size): Pair<Int, String> {
            val socket = ssl?.socketFactory?.createSocket("127.0.0.1", server.listeningPort) ?: Socket("127.0.0.1", server.listeningPort)
            return socket.use {
                it.soTimeout = 5000
                it.outputStream.write(("$method $path HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer $token\r\nContent-Length: $length\r\nConnection: close\r\n\r\n").toByteArray())
                it.outputStream.write(body); it.outputStream.flush()
                if (length > body.size) it.shutdownOutput()
                val response = it.inputStream.readBytes().toString(Charsets.UTF_8)
                response.substringBefore("\r\n").split(" ")[1].toInt() to response.substringAfter("\r\n\r\n")
            }
        }
        fun offer(bytes: ByteArray, hash: String = digest(bytes), name: String = "photo.jpg"): String {
            val response = request("POST", "/offer", JSONObject().put("name", name).put("size", bytes.size).put("sha256", hash).toString().toByteArray())
            assertEquals(response.second, 200, response.first)
            return JSONObject(response.second).getString("id")
        }
        override fun close() { inbox.close(); server.stop(); directory.deleteRecursively() }
    }
    @Test fun pinnedTlsUploadRequiresAcceptanceAndReturnsVerifiedReceipt() {
        Fixture(tls = true).use { f ->
            val bytes = ByteArray(900_001) { (it % 251).toByte() }
            val id = f.offer(bytes, name = "../../photo.jpg")
            assertEquals(409, f.request("PUT", "/upload?id=$id", bytes).first)
            assertTrue(f.directory.listFiles().isNullOrEmpty())
            f.inbox.decide(true)
            val response = f.request("PUT", "/upload?id=$id", bytes)
            assertEquals(response.second, 200, response.first)
            val receipt = JSONObject(response.second)
            assertEquals("complete", receipt.getString("state"))
            assertEquals(bytes.size.toLong(), receipt.getLong("bytes"))
            assertEquals(digest(bytes), receipt.getString("sha256"))
            val saved = f.inbox.snapshot()!!.saved!!
            assertEquals(f.directory.canonicalPath, saved.parentFile!!.canonicalPath)
            assertArrayEquals(bytes, saved.readBytes())
            assertEquals(409, f.request("PUT", "/upload?id=$id", bytes).first)
            assertEquals("complete", JSONObject(f.request("GET", "/offer?id=$id").second).getString("state"))
        }
    }
    @Test fun authorizationAndMetadataAreCheckedBeforeAnyFileIsCreated() {
        Fixture().use { f ->
            assertEquals(403, f.request("POST", "/offer", "{}".toByteArray(), token = "wrong").first)
            assertNull(f.inbox.snapshot())
            assertEquals(400, f.request("POST", "/offer", ByteArray(4097)).first)
            assertEquals(400, f.request("POST", "/offer", "{}".toByteArray()).first)
            assertTrue(f.directory.listFiles().isNullOrEmpty())
        }
    }
    @Test fun rejectionAndRevocationPreventUploadsAndAllowANewOffer() {
        Fixture().use { f ->
            val bytes = byteArrayOf(1, 2, 3)
            val rejected = f.offer(bytes); f.inbox.decide(false)
            assertEquals(409, f.request("PUT", "/upload?id=$rejected", bytes).first)
            val cancelled = f.offer(bytes); f.inbox.decide(true)
            assertEquals(200, f.request("DELETE", "/offer?id=$cancelled").first)
            assertEquals(409, f.request("PUT", "/upload?id=$cancelled", bytes).first)
            assertTrue(f.directory.listFiles().isNullOrEmpty())
        }
    }
    @Test fun wrongHashAndTruncatedBodyLeaveNoPartialOrSavedFiles() {
        Fixture().use { f ->
            val bytes = ByteArray(4096) { 1 }
            val wrongHash = f.offer(bytes, "0".repeat(64)); f.inbox.decide(true)
            assertEquals(400, f.request("PUT", "/upload?id=$wrongHash", bytes).first)
            assertEquals("failed", f.inbox.snapshot()!!.state)
            assertTrue(f.directory.listFiles().isNullOrEmpty())
            val short = f.offer(bytes); f.inbox.decide(true)
            assertEquals(400, f.request("PUT", "/upload?id=$short", bytes.copyOf(100), length = bytes.size).first)
            assertTrue(f.directory.listFiles().isNullOrEmpty())
        }
    }
    @Test fun diskSpaceIsCheckedAgainAfterAcceptance() {
        var free = Long.MAX_VALUE
        Fixture(space = { free }).use { f ->
            val bytes = ByteArray(10)
            val id = f.offer(bytes); f.inbox.decide(true); free = 0
            assertEquals(507, f.request("PUT", "/upload?id=$id", bytes).first)
            assertTrue(f.directory.listFiles().isNullOrEmpty())
            assertEquals(507, f.request("POST", "/offer", JSONObject().put("name", "x").put("size", 10).put("sha256", digest(bytes)).toString().toByteArray()).first)
        }
    }
    @Test fun emptyFileAndOfferIsolationWork() {
        Fixture().use { f ->
            val id = f.offer(byteArrayOf())
            assertEquals(409, f.request("POST", "/offer", JSONObject().put("name", "x").put("size", 0).put("sha256", digest(byteArrayOf())).toString().toByteArray()).first)
            assertEquals(404, f.request("GET", "/offer?id=wrong").first)
            f.inbox.decide(true)
            assertEquals(200, f.request("PUT", "/upload?id=$id").first)
            assertEquals(0L, f.inbox.snapshot()!!.saved!!.length())
        }
    }
    companion object {
        private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
}
