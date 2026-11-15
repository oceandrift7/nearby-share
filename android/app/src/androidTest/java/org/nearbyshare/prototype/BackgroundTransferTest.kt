package org.nearbyshare.prototype

import android.app.Notification
import android.app.NotificationManager
import android.content.*
import android.os.IBinder
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class BackgroundTransferTest {
    @Test fun notificationIsOngoingPrivateAndHasAStopControl() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val latch=CountDownLatch(1)
        var service: ShareSessionService?=null
        val connection=object: ServiceConnection {
            override fun onServiceConnected(name: ComponentName,binder: IBinder) { service=(binder as ShareSessionService.LocalBinder).service; latch.countDown() }
            override fun onServiceDisconnected(name: ComponentName) {}
        }
        assertTrue(context.bindService(Intent(context,ShareSessionService::class.java),connection,Context.BIND_AUTO_CREATE))
        try {
            assertTrue(latch.await(10,TimeUnit.SECONDS))
            val notification=service!!.notification("Receiving · 50%",50,100)
            assertEquals(Notification.CATEGORY_PROGRESS,notification.category)
            assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
            assertEquals(Notification.VISIBILITY_PRIVATE,notification.visibility)
            assertNotNull(notification.publicVersion)
            assertEquals("Open Nearby for details",notification.publicVersion.extras.getCharSequence(Notification.EXTRA_TEXT))
            assertEquals(500,notification.extras.getInt(Notification.EXTRA_PROGRESS))
            assertEquals("Stop sharing",notification.actions.single().title)
            assertEquals(NotificationManager.IMPORTANCE_LOW,context.getSystemService(NotificationManager::class.java).getNotificationChannel(ShareSessionService.CHANNEL).importance)
        } finally { context.unbindService(connection) }
    }
    @Test fun realServerReportsAuthorizedFullAndResumedBytePositionsWithoutChangingPayload() {
        val directory=InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val file=File.createTempFile("notice", ".bin",directory)
        val expected="a".repeat(300_001); file.writeText(expected)
        val calls=Collections.synchronizedList(mutableListOf<Pair<Long,Long>>())
        try {
            ReceiveInboxTest.Fixture(tls=true,outgoing=file,outgoingManifest=JSONObject().put("sha256","a".repeat(64))).use { fixture ->
                fixture.server.onTransferProgress={ bytes,total -> calls.add(bytes to total) }
                assertEquals(403,fixture.request("GET","/file",token="wrong").first)
                assertTrue(calls.isEmpty())
                assertEquals(expected,fixture.request("GET","/file").second)
                assertEquals(file.length() to file.length(),calls.last())
                calls.clear()
                val response=fixture.request("GET","/file",extraHeaders="Range: bytes=200000-300000\r\nIf-Match: \"${"a".repeat(64)}\"\r\n")
                assertEquals(206,response.first); assertEquals(expected.substring(200000),response.second)
                assertEquals(file.length() to file.length(),calls.last())
                assertTrue(calls.all { it.first in 200001..file.length() && it.second==file.length() })
                fixture.server.onTransferProgress={ _,_ -> error("Notification unavailable") }
                assertEquals(expected,fixture.request("GET","/file").second)
            }
        } finally { file.delete() }
    }
}
