package org.nearbyshare.prototype

import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID

/** One explicitly accepted incoming file per session; never uses a peer's name as a path. */
class ReceiveInbox(private val directory: File, private val availableSpace: () -> Long = { directory.usableSpace },
                   private val changed: () -> Unit = {}) {
    data class Offer(val id: String, val name: String, val size: Long, val hash: String,
                     var state: String = "waiting", var bytes: Long = 0, var saved: File? = null,
                     var error: String? = null) {
        fun json() = JSONObject().put("id", id).put("state", state).put("bytes", bytes)
            .put("size", size).put("sha256", hash).put("error", error ?: JSONObject.NULL)
    }
    private val lock = Any()
    private var current: Offer? = null
    private var closed = false
    private var activeInput: InputStream? = null
    init { directory.mkdirs() }
    fun snapshot(): Offer? = synchronized(lock) { current?.copy() }

    fun decide(id: String, accept: Boolean) {
        synchronized(lock) {
            val item = current ?: return
            if (closed || item.id != id || item.state != "waiting") return
            if (accept && availableSpace() < item.size + RESERVE) {
                item.state = "failed"; item.error = "Not enough free storage on Android."
            } else item.state = if (accept) "accepted" else "rejected"
        }
        changed()
    }

    fun close() {
        val input = synchronized(lock) {
            closed = true
            current?.let { if (it.state !in TERMINAL) it.state = "cancelled" }
            activeInput
        }
        try { input?.close() } catch (_: Exception) {}
    }

    fun serve(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        // Always close these HTTP connections: a rejected body must not become a next request.
        val response = try {
            when {
                session.uri == "/offer" && session.method == NanoHTTPD.Method.POST -> offer(session)
                session.uri == "/offer" && session.method == NanoHTTPD.Method.GET -> {
                    val item = synchronized(lock) { matching(session)?.copy() }
                    if (item == null) reply(404, "Unknown offer") else json(item.json())
                }
                session.uri == "/offer" && session.method == NanoHTTPD.Method.DELETE -> {
                    val input = synchronized(lock) {
                        val item = matching(session) ?: return reply(404, "Unknown offer")
                        if (item.state !in TERMINAL) item.state = "cancelled"
                        activeInput
                    }
                    try { input?.close() } catch (_: Exception) {}
                    changed(); json(JSONObject().put("state", snapshot()?.state))
                }
                session.uri == "/upload" && session.method == NanoHTTPD.Method.PUT -> upload(session)
                else -> reply(404, "Not found")
            }
        } catch (_: Exception) { reply(400, "Invalid or incomplete request") }
        response.addHeader("Connection", "close")
        response.addHeader("Cache-Control", "no-store")
        return response
    }

    private fun matching(session: NanoHTTPD.IHTTPSession): Offer? {
        if (closed) return null
        return current?.takeIf { it.id == session.parameters["id"]?.singleOrNull() }
    }
    private fun length(session: NanoHTTPD.IHTTPSession): Long? {
        if (session.headers.containsKey("transfer-encoding")) return null
        return session.headers["content-length"]?.toLongOrNull()?.takeIf { it >= 0 }
    }
    private fun offer(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        val length = length(session) ?: return reply(400, "Content-Length required")
        if (length !in 1..4096) return reply(400, "Offer too large")
        val bytes = ByteArray(length.toInt())
        var offset = 0
        while (offset < bytes.size) {
            val count = session.inputStream.read(bytes, offset, bytes.size - offset)
            if (count <= 0) return reply(400, "Incomplete offer")
            offset += count
        }
        val body = JSONObject(String(bytes, Charsets.UTF_8))
        val name = body.getString("name")
        val size = body.getLong("size")
        val hash = body.getString("sha256")
        if (name.toByteArray(Charsets.UTF_8).size !in 1..1024 || name.any { it.isISOControl() } ||
            size !in 0..1_099_511_627_776L || !hash.matches(Regex("[0-9a-f]{64}"))) return reply(400, "Invalid metadata")
        val item = synchronized(lock) {
            if (closed || activeInput != null || current?.state?.let { it !in TERMINAL } == true) return reply(409, "An offer is already active")
            if (availableSpace() < size + RESERVE) return reply(507, "Not enough free storage on Android")
            // The POST receipt must remain a stable waiting snapshot even if the
            // UI accepts immediately after the notification below.
            Offer(UUID.randomUUID().toString(), name, size, hash).also { current = it }.copy()
        }
        changed()
        return json(item.json())
    }

    private fun upload(session: NanoHTTPD.IHTTPSession): NanoHTTPD.Response {
        val item = synchronized(lock) {
            val item = matching(session) ?: return reply(404, "Unknown offer")
            if (item.state != "accepted") return reply(409, "Accept this offer on Android first")
            if (length(session) != item.size) return reply(400, "Incorrect Content-Length")
            if (availableSpace() < item.size + RESERVE) {
                item.state = "failed"; item.error = "Not enough free storage on Android."
                changed(); return reply(507, item.error!!)
            }
            item.state = "receiving"; activeInput = session.inputStream
            item
        }
        val partial = File(directory, "${item.id}.partial")
        val target = File(directory, "${item.id}.received")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var total = 0L
            var lastUpdate = 0L
            partial.outputStream().buffered(262144).use { output ->
                val buffer = ByteArray(262144)
                while (total < item.size) {
                    synchronized(lock) { check(!closed && item.state == "receiving") { "Transfer cancelled" } }
                    val count = session.inputStream.read(buffer, 0, minOf(buffer.size.toLong(), item.size - total).toInt())
                    check(count > 0) { "Connection ended before the file was complete" }
                    output.write(buffer, 0, count); digest.update(buffer, 0, count); total += count
                    synchronized(lock) { item.bytes = total }
                    val now = System.nanoTime()
                    if (now - lastUpdate > 250_000_000) { lastUpdate = now; changed() }
                }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            check(actual == item.hash) { "Integrity check failed; file discarded" }
            synchronized(lock) {
                check(!closed && item.state == "receiving") { "Transfer cancelled" }
                check(partial.renameTo(target)) { "Could not save received file" }
                File(directory, "${item.id}.json").writeText(JSONObject().put("name", item.name).toString())
                item.saved = target; item.state = "complete"
            }
            return json(item.json())
        } catch (error: Exception) {
            target.delete(); File(directory, "${item.id}.json").delete()
            synchronized(lock) {
                if (item.state != "cancelled") { item.state = "failed"; item.error = error.message ?: "Transfer failed" }
            }
            return reply(400, "Transfer failed; incomplete file discarded")
        } finally {
            partial.delete()
            synchronized(lock) { activeInput = null }
            changed()
        }
    }
    private fun json(value: JSONObject) = response(200, "application/json", value.toString())
    private fun reply(code: Int, message: String) = response(code, "application/json", JSONObject().put("error", message).toString())
    private fun response(code: Int, mime: String, body: String): NanoHTTPD.Response {
        val status = object : NanoHTTPD.Response.IStatus {
            override fun getRequestStatus() = code
            override fun getDescription() = "$code ${if (code == 200) "OK" else "Error"}"
        }
        return NanoHTTPD.newFixedLengthResponse(status, mime, body).also {
            it.addHeader("Connection", "close"); it.addHeader("Cache-Control", "no-store")
        }
    }
    companion object {
        const val RESERVE = 16L * 1024 * 1024
        private val TERMINAL = setOf("complete", "failed", "cancelled", "rejected")
    }
}
