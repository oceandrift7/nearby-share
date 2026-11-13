package org.nearbyshare.prototype

import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject
import java.io.File

// The activity enables TLS before starting this server. The port is injectable
// so endpoint/stream lifecycle tests can use an ephemeral local listener.
class SharedFileServer(port: Int, private val token: String, private val file: File,
                       private val manifest: JSONObject, private val onFileRequested: () -> Unit) : NanoHTTPD(port) {
    private val readReports = SenderReadReports()
    override fun serve(session: IHTTPSession): Response {
        if (session.method != Method.GET || session.headers["authorization"] != "Bearer $token")
            return newFixedLengthResponse(Response.Status.FORBIDDEN, "text/plain", "Pairing required")
        val response = when (session.uri) {
            "/manifest" -> newFixedLengthResponse(Response.Status.OK, "application/json", manifest.toString())
            "/file" -> {
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
