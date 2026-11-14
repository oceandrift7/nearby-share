package org.nearbyshare.prototype

import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject
import java.io.File

// The activity enables TLS before starting this server. The port is injectable
// so endpoint/stream lifecycle tests can use an ephemeral local listener.
class SharedFileServer(port: Int, private val token: String, private val file: File?,
                       private val manifest: JSONObject, private val inbox: ReceiveInbox? = null,
                       private val onFileRequested: () -> Unit) : NanoHTTPD(port) {
    private val readReports = SenderReadReports()
    internal val connections = LimitedConnections()
    init { setAsyncRunner(connections) }
    override fun serve(session: IHTTPSession): Response {
        if (session.headers["authorization"] != "Bearer $token")
            return newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "Pairing required").also { it.addHeader("Connection", "close") }
        if (inbox != null && session.uri in listOf("/offer", "/upload")) return inbox.serve(session)
        if (session.method != Method.GET)
            return newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "GET required").also { it.addHeader("Connection", "close") }
        val response = when (session.uri) {
            "/manifest" -> newFixedLengthResponse(Response.Status.OK, "application/json",
                JSONObject(manifest.toString()).put("supportsResume", file != null).toString())
            "/file" -> {
                if (file == null) return newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "No outgoing file")
                val rangeHeader = session.headers["range"]
                if (rangeHeader != null) {
                    val etag = "\"${manifest.optString("sha256")}\""
                    if (session.headers["if-match"] != etag)
                        return newFixedLengthResponse(Response.Status.PRECONDITION_FAILED, "text/plain", "File changed").also { it.addHeader("Cache-Control", "no-store") }
                    val match = Regex("bytes=([0-9]+)-([0-9]+)").matchEntire(rangeHeader)
                    val start = match?.groupValues?.get(1)?.toLongOrNull()
                    val end = match?.groupValues?.get(2)?.toLongOrNull()
                    if (start == null || end == null || start < 0 || end < start || end >= file.length() || end - start >= 4L * 1024 * 1024)
                        return newFixedLengthResponse(Response.Status.RANGE_NOT_SATISFIABLE, "text/plain", "Invalid range").also {
                            it.addHeader("Content-Range", "bytes */${file.length()}"); it.addHeader("Cache-Control", "no-store")
                        }
                    onFileRequested()
                    val source = file.inputStream()
                    source.channel.position(start)
                    return newFixedLengthResponse(Response.Status.PARTIAL_CONTENT, "application/octet-stream", source.buffered(262144), end - start + 1).also {
                        it.addHeader("Content-Range", "bytes $start-$end/${file.length()}")
                        it.addHeader("ETag", etag); it.addHeader("Accept-Ranges", "bytes"); it.addHeader("Cache-Control", "no-store")
                    }
                }
                onFileRequested()
                val id = session.headers["x-nearby-transfer-id"]
                val input = file.inputStream().buffered(262144)
                val measured = if (readReports.validID(id)) TimedSnapshotInputStream(input) { readReports.put(id!!, it) } else input
                newFixedLengthResponse(Response.Status.OK, "application/octet-stream", measured, file.length())
            }
            "/transfer-stats" -> {
                val id = session.parameters["id"]?.firstOrNull()
                val stats = if (readReports.validID(id)) readReports.get(id) else null
                if (stats == null) newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "No completed measurement")
                else newFixedLengthResponse(Response.Status.OK, "application/json", stats.json().toString())
            }
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Not found")
        }
        response.addHeader("Cache-Control", "no-store")
        return response
    }
}
