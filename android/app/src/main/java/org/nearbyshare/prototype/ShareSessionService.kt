package org.nearbyshare.prototype

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.SecureRandom
import java.util.concurrent.Executors

/** The service owns the hotspot/server; closing the Activity only detaches its UI. */
class ShareSessionService : Service() {
    inner class LocalBinder : Binder() { val service get() = this@ShareSessionService }
    private val binder = LocalBinder()
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var generation = 0
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var server: SharedFileServer? = null
    var inbox: ReceiveInbox? = null; private set
    var pairingCode: String? = null; private set
    var wifiCode: String? = null; private set
    var message = "Ready. No internet needed."; private set
    var active = false; private set
    var listener: (() -> Unit)? = null
    private var lastNotice = 0L
    private var wake: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var lastTraffic = 0L
    private val idleWake = object : Runnable {
        override fun run() {
            if (!active) return
            if (SystemClock.elapsedRealtime() - lastTraffic >= 15_000 && wake?.isHeld == true) wake?.release()
            main.postDelayed(this, 15_000)
        }
    }
    override fun onBind(intent: Intent?) = binder
    override fun onCreate() {
        super.onCreate()
        cacheDir.listFiles()?.filter { it.name.startsWith("outgoing-") && it.name.endsWith(".bin") }?.forEach { it.delete() }
        File(filesDir,"received").listFiles()?.filter { it.extension=="partial" }?.forEach { it.delete() }
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "Nearby transfers", NotificationManager.IMPORTANCE_LOW))
        wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:transfer").apply { setReferenceCounted(false) }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) stopSharing()
        else if (!active) stopSelf(startId)
        return START_NOT_STICKY // Never revive an old authorized sharing session automatically.
    }
    internal fun notification(text: String, bytes: Long = 0, total: Long = 0): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, ShareSessionService::class.java).setAction(STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val public = Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_upload).setContentTitle("Nearby transfer").setContentText("Open Nearby for details").build()
        return Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Nearby transfer").setContentText(text).setContentIntent(open)
            .setCategory(Notification.CATEGORY_PROGRESS).setOnlyAlertOnce(true).setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(public)
            .setProgress(1000, if (total > 0) ((bytes.coerceIn(0,total).toDouble()/total)*1000).toInt() else 0, total <= 0)
            .addAction(Notification.Action.Builder(null, "Stop sharing", stop).build()).build()
    }
    private fun notice(text: String, bytes: Long = 0, total: Long = 0, force: Boolean = false) {
        if (!active) return
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return
        val now = SystemClock.elapsedRealtime()
        if (!force && now-lastNotice < 500) return
        lastNotice = now
        getSystemService(NotificationManager::class.java).notify(NOTICE, notification(text,bytes,total))
    }
    private fun traffic() {
        lastTraffic = SystemClock.elapsedRealtime()
        if (wake?.isHeld != true) wake?.acquire(60_000)
    }
    private fun publish(text: String) { message = text; listener?.invoke() }

    fun startSharing(name: String, file: File?, hash: String) {
        stopSharing(stopService = false)
        val run = generation
        try {
            if (file != null) {
                val root = File(filesDir,"saved-outgoing").canonicalFile
                require(file.canonicalFile.parentFile == root && file.isFile) { "Choose a saved file again." }
            }
            active = true
            startForegroundService(Intent(this, ShareSessionService::class.java))
            startForeground(NOTICE,notification("Starting offline connection…"),ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            @Suppress("DEPRECATION")
            val lock = getSystemService(WifiManager::class.java).createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF,"$packageName:local-transfer")
            lock.setReferenceCounted(false); lock.acquire(); wifiLock = lock
            main.post(idleWake)
            publish("Starting offline hotspot… On Android 10–12, enable Location if this fails. No location is recorded.")
            getSystemService(WifiManager::class.java).startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    if (generation != run || !active) { r.close(); return }
                    reservation = r
                    @Suppress("DEPRECATION")
                    val ssid = if (Build.VERSION.SDK_INT >= 30) r.softApConfiguration.ssid!! else r.wifiConfiguration!!.SSID
                    @Suppress("DEPRECATION")
                    val password = if (Build.VERSION.SDK_INT >= 30) r.softApConfiguration.passphrase!! else r.wifiConfiguration!!.preSharedKey
                    worker.execute {
                        var started: SharedFileServer? = null
                        var receiver: ReceiveInbox? = null
                        try {
                            val token = hex(ByteArray(32).also { SecureRandom().nextBytes(it) })
                            val identity = LocalTlsIdentity.create()
                            val diagnostics = JSONObject().put("appVersion","0.4.0").put("model",Build.MODEL).put("androidAPI",Build.VERSION.SDK_INT)
                                .put("hotspotBandMask",JSONObject.NULL).put("supports5GHz",getSystemService(WifiManager::class.java).is5GHzBandSupported)
                            val manifest = JSONObject().put("mode",if(file==null) "receive" else "send")
                                .put("name",if(file==null) "Android receiver" else name).put("size",file?.length()?:0)
                                .put("sha256",if(file==null) "0".repeat(64) else hash).put("diagnostics",diagnostics)
                            receiver = if(file==null) ReceiveInbox(File(filesDir,"received")) {
                                main.post { if(generation==run) renderIncoming() }
                            } else null
                            val host = SharedFileServer(9443,token,file,manifest,receiver) {
                                main.post { if(generation==run) { traffic(); publish("Sending $name. Check iPhone for verified completion.") } }
                            }
                            host.onTransferProgress = { bytes,total -> main.post { if(generation==run) {
                                traffic()
                                notice(if(bytes>=total) "Sent; check iPhone for verification" else "Sending · ${percent(bytes,total)}%",bytes,total,bytes>=total)
                            } } }
                            started = host
                            host.makeSecure(identity.context.serverSocketFactory, LocalTlsIdentity.protocols); host.start(30_000,true)
                            main.post { if(generation==run) publish("Checking encrypted connection…") }
                            TlsSelfTest.verify(identity,host.listeningPort,token)
                            var addresses = emptyList<String>()
                            repeat(10) {
                                check(generation==run) { "Setup cancelled" }
                                addresses = (addresses+NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp&&!it.isLoopback }
                                    .flatMap { it.inetAddresses.toList() }.filterIsInstance<Inet4Address>().filter { it.isSiteLocalAddress }.map { it.hostAddress!! }).distinct().take(16)
                                Thread.sleep(200)
                            }
                            check(addresses.isNotEmpty()) { "No local hotspot address found. Stop and retry." }
                            val pairing = JSONObject().put("v",1).put("ssid",ssid).put("password",password).put("hosts",JSONArray(addresses))
                                .put("port",9443).put("token",token).put("certificateSHA256",identity.pin).toString()
                            val newInbox = receiver
                            main.post {
                                if(generation!=run||!active) { host.stop(); newInbox?.close() }
                                else {
                                    server=host; inbox=newInbox; pairingCode=pairing; wifiCode=WifiQr.encode(ssid,password)
                                    notice(if(file==null) "Ready to receive · tap to pair" else "Ready to share · tap to pair",force=true)
                                    publish(if(file==null) "Ready to receive. Pair the iPhone and choose a file there. You can leave Nearby; use its notification to return or stop."
                                        else "Ready to share $name (${file.length()} bytes). Nearby stays active through its notification.")
                                }
                            }
                        } catch(error: Exception) {
                            started?.stop(); receiver?.close()
                            main.post { if(generation==run) fail("Setup failed: ${error.message}") }
                        }
                    }
                }
                override fun onFailed(reason: Int) { if(generation==run) fail("Hotspot failed ($reason). Enable Wi-Fi and Location; turn off existing tethering, then retry.") }
                override fun onStopped() { if(generation==run) fail("Hotspot stopped. Share the saved file again to reconnect.") }
            },main)
        } catch(error: SecurityException) { fail("Hotspot permission was denied or revoked. Allow Nearby's connection permission and retry.") }
        catch(error: Exception) { fail("Could not start sharing: ${error.message}") }
    }
    private fun renderIncoming() {
        val item=inbox?.snapshot()?:return
        if(item.state=="receiving") traffic()
        notice(when(item.state) {
            "waiting" -> "Incoming file · open Nearby to accept"
            "accepted" -> "Accepted · waiting for iPhone"
            "receiving" -> "Receiving · ${percent(item.bytes,item.size)}%"
            "complete" -> "Verified and saved · tap to export"
            "failed" -> "Transfer interrupted · tap for details"
            else -> "Ready for another transfer"
        },item.bytes,item.size,item.state!="receiving")
        listener?.invoke()
    }
    private fun fail(text: String) { stopSharing(); publish(text) }
    fun stopSharing(stopService: Boolean = true) {
        generation++; active=false
        pairingCode=null; wifiCode=null
        inbox?.close(); inbox=null; server?.stop(); server=null
        val old=reservation; reservation=null; old?.close()
        main.removeCallbacks(idleWake)
        if(wake?.isHeld==true) wake?.release()
        if(wifiLock?.isHeld==true) wifiLock?.release(); wifiLock=null
        stopForeground(STOP_FOREGROUND_REMOVE)
        publish("Sharing stopped. Previous code is invalid. Saved files can be shared again without the picker.")
        if(stopService) stopSelf()
    }
    override fun onDestroy() { stopSharing(stopService=false); listener=null; worker.shutdown(); super.onDestroy() }
    private fun hex(bytes: ByteArray)=bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun percent(bytes: Long,total: Long)=if(total>0) ((bytes.coerceIn(0,total).toDouble()/total)*100).toInt() else 0
    companion object {
        const val CHANNEL="nearby-transfers"
        const val NOTICE=44
        const val STOP="org.nearbyshare.prototype.STOP_SHARING"
    }
}
