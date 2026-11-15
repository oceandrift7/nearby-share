package org.nearbyshare.prototype

import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Up to three immutable private snapshots, never paths supplied by a peer. */
internal class SavedOutgoingFiles(private val directory: File) {
    data class Item(val id: String, val name: String, val size: Long, val hash: String, val file: File)
    private val metadata = AtomicFile(File(directory, "selections.json"))
    private val idPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

    @Synchronized fun all(): List<Item> {
        return try {
            val bytes = metadata.openRead().use { it.readBytes() }
            require(bytes.size <= 16384)
            val array = JSONArray(String(bytes, Charsets.UTF_8))
            require(array.length() <= 3)
            (0 until array.length()).mapNotNull { index ->
                val value = array.getJSONObject(index)
                val id = value.getString("id")
                val name = value.getString("name")
                val size = value.getLong("size")
                val hash = value.getString("sha256")
                val file = File(directory, "$id.bin")
                if (!idPattern.matches(id) || name.toByteArray(Charsets.UTF_8).size !in 1..1024 ||
                    size < 0 || !hash.matches(Regex("[0-9a-f]{64}")) || !file.isFile || file.length() != size) null
                else Item(id, name, size, hash, file)
            }
        } catch (_: Exception) { emptyList() }
    }

    @Synchronized fun remember(snapshot: File, name: String, hash: String, active: () -> Boolean = { true }): Item {
        require(name.toByteArray(Charsets.UTF_8).size in 1..1024 && hash.matches(Regex("[0-9a-f]{64}")))
        check(active()) { "Preparation cancelled" }
        check(directory.isDirectory || directory.mkdirs()) { "Could not create saved selection storage" }
        val previous = all()
        // Identical content reuses the existing snapshot rather than keeping duplicates.
        val same = previous.firstOrNull { it.hash == hash && it.size == snapshot.length() && it.name == name }
        val item = same ?: run {
            val id = UUID.randomUUID().toString()
            val target = File(directory, "$id.bin")
            check(snapshot.renameTo(target)) { "Could not retain the prepared file" }
            Item(id, name, target.length(), hash, target)
        }
        val retained = (listOf(item) + previous.filter { it.id != item.id }).take(3)
        val array = JSONArray()
        retained.forEach { array.put(JSONObject().put("id", it.id).put("name", it.name).put("size", it.size).put("sha256", it.hash)) }
        var stream: java.io.FileOutputStream? = null
        try {
            check(active()) { "Preparation cancelled" }
            stream = metadata.startWrite()
            stream.write(array.toString().toByteArray(Charsets.UTF_8))
            check(active()) { "Preparation cancelled" }
            metadata.finishWrite(stream); stream = null
        } catch (error: Exception) {
            stream?.let { metadata.failWrite(it) }
            if (same == null) item.file.delete()
            throw error
        }
        if (same != null) snapshot.delete()
        val retainedNames = retained.map { it.file.name }.toSet()
        directory.listFiles()?.filter { it.extension == "bin" && idPattern.matches(it.nameWithoutExtension) && it.name !in retainedNames }?.forEach { it.delete() }
        return item
    }

    @Synchronized fun forgetAll() {
        metadata.delete()
        directory.listFiles()?.filter { it.extension == "bin" && idPattern.matches(it.nameWithoutExtension) }?.forEach { it.delete() }
    }
}
