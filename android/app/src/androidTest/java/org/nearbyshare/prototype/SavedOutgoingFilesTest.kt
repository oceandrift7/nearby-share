package org.nearbyshare.prototype

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class SavedOutgoingFilesTest {
    private fun test(block: (File, SavedOutgoingFiles) -> Unit) {
        val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "saved-test-${UUID.randomUUID()}")
        directory.mkdirs()
        try { block(directory, SavedOutgoingFiles(File(directory,"saved"))) }
        finally { directory.deleteRecursively() }
    }
    private fun snapshot(directory: File, value: Int): File = File.createTempFile("snapshot", ".bin", directory).apply { writeBytes(ByteArray(1000) { value.toByte() }) }
    private fun hash(file: File) = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it.toInt() and 255) }

    @Test fun selectionsSurviveStoreRecreationAndKeepOriginalLabelAndContents() = test { directory, store ->
        val input = snapshot(directory,7); val bytes = input.readBytes(); val digest = hash(input)
        val item = store.remember(input,"صورة.jpg",digest)
        val reopened = SavedOutgoingFiles(File(directory,"saved")).all().single()
        assertEquals(item.id,reopened.id); assertEquals("صورة.jpg",reopened.name); assertEquals(digest,reopened.hash)
        assertArrayEquals(bytes,reopened.file.readBytes()); assertFalse(input.exists())
    }
    @Test fun savedCopiesAreBoundedToThreeAndRepeatedSelectionDoesNotDuplicate() = test { directory, store ->
        val ids = (1..4).map { value -> val input=snapshot(directory,value); store.remember(input,"file$value",hash(input)).id }
        assertEquals(3,store.all().size); assertFalse(store.all().any { it.id==ids.first() })
        assertFalse(File(directory,"saved/${ids.first()}.bin").exists())
        val same=snapshot(directory,4); val reused=store.remember(same,"file4",hash(same))
        assertEquals(ids.last(),reused.id); assertEquals(3,store.all().size)
    }
    @Test fun cancelledRememberKeepsOldSelectionAndForgetDoesNotDeleteOriginals() = test { directory, store ->
        val original=File(directory,"original.txt").apply { writeText("keep me") }
        val input=snapshot(directory,1); val item=store.remember(input,"one",hash(input))
        val cancelled=snapshot(directory,2)
        try { store.remember(cancelled,"two",hash(cancelled)) { false }; fail("Cancelled snapshot retained") }
        catch (_: IllegalStateException) {}
        assertEquals(item.id,store.all().single().id)
        store.forgetAll(); assertTrue(store.all().isEmpty()); assertFalse(item.file.exists())
        assertEquals("keep me",original.readText())
    }
    @Test fun metadataCannotPointOutsidePrivateSnapshotDirectory() = test { directory, store ->
        val outside=File(directory,"outside.bin").apply { writeText("outside") }
        val input=snapshot(directory,1); store.remember(input,"label",hash(input))
        File(directory,"saved/selections.json").writeText("[{\"id\":\"../outside\",\"name\":\"bad\",\"size\":7,\"sha256\":\"${"0".repeat(64)}\"}]")
        assertTrue(store.all().isEmpty()); store.forgetAll(); assertTrue(outside.exists())
    }
    @Test fun cancellationBeforeMetadataCommitRollsBackToPreviousSelection() = test { directory, store ->
        val first=snapshot(directory,1); val old=store.remember(first,"one",hash(first))
        val second=snapshot(directory,2)
        var checks=0
        try { store.remember(second,"two",hash(second)) { ++checks < 3 }; fail("Cancelled write committed") }
        catch (_: IllegalStateException) {}
        val restored=SavedOutgoingFiles(File(directory,"saved")).all().single()
        assertEquals(old.id,restored.id); assertTrue(restored.file.exists())
        assertEquals(1,File(directory,"saved").listFiles()!!.count { it.extension=="bin" })
    }
}
