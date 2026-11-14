package org.nearbyshare.prototype

import fi.iki.elonen.NanoHTTPD

/** Bounds threads/sockets before TLS and HTTP authentication. No waiting queue. */
internal class LimitedConnections(private val limit: Int = 8) : NanoHTTPD.DefaultAsyncRunner() {
    private var stopping = false
    val activeCount: Int get() = running.size

    @Synchronized override fun exec(client: NanoHTTPD.ClientHandler) {
        if (stopping || running.size >= limit) client.close()
        else super.exec(client)
    }

    @Synchronized override fun closeAll() {
        stopping = true
        super.closeAll()
    }
}
