package org.nearbyshare.prototype

import java.io.FilterInputStream
import java.io.InputStream
import org.json.JSONObject

data class SenderReadStats(val bytes: Long, val calls: Long, val nanoseconds: Long) {
    fun json() = JSONObject().put("bytes", bytes).put("calls", calls)
        .put("readSeconds", nanoseconds / 1_000_000_000.0)
}

// Time only reads from the buffered snapshot. Socket writes/TLS, scheduling
// between reads, and receiver storage are outside this measurement.
class TimedSnapshotInputStream(input: InputStream, private val complete: (SenderReadStats) -> Unit) : FilterInputStream(input) {
    private var bytes = 0L
    private var calls = 0L
    private var nanoseconds = 0L
    private var closed = false

    override fun read(): Int {
        val start = System.nanoTime()
        try { return `in`.read().also { if (it >= 0) bytes++ } }
        finally { calls++; nanoseconds += System.nanoTime() - start }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val start = System.nanoTime()
        try { return `in`.read(buffer, offset, length).also { if (it > 0) bytes += it } }
        finally { calls++; nanoseconds += System.nanoTime() - start }
    }

    override fun close() {
        if (closed) return
        closed = true
        try { super.close() } finally { complete(SenderReadStats(bytes, calls, nanoseconds)) }
    }
}

// Bounded, per-session records. IDs are generated per download by the receiver,
// so overlapping transfers cannot silently report each other's measurements.
class SenderReadReports {
    private val records = LinkedHashMap<String, SenderReadStats>()
    fun validID(id: String?) = id != null && id.matches(Regex("[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}"))
    @Synchronized fun put(id: String, stats: SenderReadStats) {
        if (!validID(id)) return
        records.remove(id)
        records[id] = stats
        while (records.size > 8) records.remove(records.keys.first())
    }
    @Synchronized fun get(id: String?) = records[id]
}
