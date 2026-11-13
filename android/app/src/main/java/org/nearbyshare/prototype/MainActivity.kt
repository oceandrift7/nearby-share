package org.nearbyshare.prototype

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.WindowManager
import android.widget.*
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var qr: ImageView
    private lateinit var choose: Button
    private lateinit var qrSteps: LinearLayout
    private lateinit var qrHelp: TextView
    private var wifiBitmap: Bitmap? = null
    private var pairingBitmap: Bitmap? = null
    private val worker = Executors.newSingleThreadExecutor()
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var server: NanoHTTPD? = null
    private var selected: File? = null
    private var generation = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        cacheDir.listFiles()?.filter { it.name.startsWith("outgoing-") && it.name.endsWith(".bin") }?.forEach { it.delete() }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(32, 32, 32, 32) }
        layout.addView(TextView(this).apply { text = "Nearby • prototype 0.1.4"; textSize = 24f })
        layout.addView(TextView(this).apply { text = "Android → iPhone only in this first build. Choose one file, then follow the two QR steps below. Keep both apps open. Anyone scanning the code can download the selected file until you stop." })
        choose = Button(this).apply {
            text = "Choose a file"
            setOnClickListener { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                type = "*/*"; addCategory(Intent.CATEGORY_OPENABLE)
            }, 10) }
        }
        layout.addView(choose)
        layout.addView(Button(this).apply { text = "Stop sharing"; setOnClickListener { stopSharing() } })
        status = TextView(this).apply { text = "Ready. No internet needed." }
        layout.addView(status)
        qrSteps = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = android.view.View.GONE
            addView(Button(this@MainActivity).apply {
                text = "1. Show Wi-Fi code"
                setOnClickListener { showCode(wifi = true) }
            })
            addView(Button(this@MainActivity).apply {
                text = "2. Show Nearby pairing code"
                setOnClickListener { showCode(wifi = false) }
            })
        }
        layout.addView(qrSteps)
        qrHelp = TextView(this)
        layout.addView(qrHelp)
        qr = ImageView(this)
        layout.addView(qr, LinearLayout.LayoutParams(-1, 800))
        setContentView(ScrollView(this).apply { addView(layout) })
    }

    @Deprecated("Prototype uses platform picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 10 || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        stopSharing()
        val run = generation
        choose.isEnabled = false
        status.text = "Preparing file and integrity checksum…"
        worker.execute {
            var snapshot: File? = null
            try {
                var name = "Shared file"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) name = it.getString(0) ?: name
                }
                // Snapshot avoids a provider changing bytes between hashing and downloading.
                val file = File.createTempFile("outgoing-", ".bin", cacheDir)
                snapshot = file
                val hash = MessageDigest.getInstance("SHA-256")
                contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().buffered(262144).use { output ->
                    val buffer = ByteArray(262144)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count); hash.update(buffer, 0, count)
                    }
                } }
                val digest = hex(hash.digest())
                runOnUiThread {
                    if (generation != run || isDestroyed) file.delete()
                    else { selected = file; startWithPermission(name, file, digest) }
                }
            } catch (e: Exception) {
                snapshot?.delete()
                runOnUiThread { if (generation == run) { choose.isEnabled = true; status.text = "Preparation failed: ${e.message}" } }
            }
        }
    }

    private var pending: (() -> Unit)? = null
    private fun startWithPermission(name: String, file: File, hash: String) {
        val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            pending = { startHotspot(name, file, hash) }
            val permissions = if (Build.VERSION.SDK_INT >= 33) arrayOf(permission)
                else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
            requestPermissions(permissions, 20)
        } else startHotspot(name, file, hash)
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        val action = pending; pending = null
        if (code == 20 && results.firstOrNull() == PackageManager.PERMISSION_GRANTED) action?.invoke()
        else if (code == 20) { status.text = "Permission required to create the temporary connection."; choose.isEnabled = true }
    }

    private fun startHotspot(name: String, file: File, hash: String) {
        val run = generation
        status.text = "Starting offline hotspot… On Android 10–12, enable Location in system settings if this fails. No location is recorded."
        try {
            getSystemService(WifiManager::class.java).startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    if (generation != run || isDestroyed) { r.close(); return }
                    reservation = r
                    @Suppress("DEPRECATION")
                    val ssid = if (Build.VERSION.SDK_INT >= 30) r.softApConfiguration.ssid!! else r.wifiConfiguration!!.SSID
                    @Suppress("DEPRECATION")
                    val password = if (Build.VERSION.SDK_INT >= 30) r.softApConfiguration.passphrase!! else r.wifiConfiguration!!.preSharedKey
                    worker.execute {
                        var startedServer: NanoHTTPD? = null
                        try {
                            val tokenBytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
                            val token = hex(tokenBytes)
                            val identity = LocalTlsIdentity.create()
                            // Public hotspot band/channel APIs are unavailable on our Android
                            // 10/12 targets. Never substitute the upstream Wi-Fi station's data.
                            val bandMask: Int? = null
                            val diagnostics = JSONObject().put("appVersion", "0.1.4")
                                .put("model", Build.MODEL).put("androidAPI", Build.VERSION.SDK_INT)
                                .put("hotspotBandMask", bandMask ?: JSONObject.NULL)
                                .put("supports5GHz", getSystemService(WifiManager::class.java).is5GHzBandSupported)
                            val manifest = JSONObject().put("name", name).put("size", file.length()).put("sha256", hash)
                                .put("diagnostics", diagnostics)
                            val host = SharedFileServer(9443, token, file, manifest) {
                                runOnUiThread { if (generation == run) status.text = "Serving $name. Check the iPhone for verified completion and speed." }
                            }
                            startedServer = host
                            host.makeSecure(identity.context.serverSocketFactory, LocalTlsIdentity.protocols)
                            host.start(30_000, true)
                            runOnUiThread { if (generation == run) status.text = "Checking encrypted connection…" }
                            TlsSelfTest.verify(identity, host.listeningPort, token)
                            // Interfaces can appear shortly after onStarted. Include all private IPv4
                            // candidates; the iPhone tries them and accepts only the pinned certificate.
                            var addresses = emptyList<String>()
                            repeat(10) {
                                    addresses = (addresses + NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
                                        .flatMap { it.inetAddresses.toList() }.filterIsInstance<Inet4Address>()
                                        .filter { it.isSiteLocalAddress }.map { it.hostAddress!! }).distinct().take(16)
                                    Thread.sleep(200)
                            }
                            if (addresses.isEmpty()) { host.stop(); error("No local hotspot address found. Stop and retry.") }
                            val pairing = JSONObject().put("v", 1).put("ssid", ssid).put("password", password)
                                .put("hosts", JSONArray(addresses)).put("port", 9443).put("token", token).put("certificateSHA256", identity.pin)
                            val pairingCode = qrBitmap(pairing.toString())
                            val wifiCode = qrBitmap(WifiQr.encode(ssid, password))
                            runOnUiThread {
                                if (generation != run || isDestroyed) host.stop()
                                else {
                                    server = host; pairingBitmap = pairingCode; wifiBitmap = wifiCode
                                    qrSteps.visibility = android.view.View.VISIBLE
                                    showCode(wifi = true)
                                    status.text = "Ready to share $name (${file.length()} bytes). Keep this app open."
                                }
                            }
                        } catch (e: Exception) {
                            startedServer?.stop()
                            runOnUiThread { if (generation == run) { stopSharing(); status.text = "Setup failed: ${e.javaClass.simpleName}: ${e.message}" } }
                        }
                    }
                }
                override fun onFailed(reason: Int) { if (generation == run) { stopSharing(); status.text = "Hotspot failed ($reason). Enable Wi-Fi and Location; turn off existing tethering, then retry." } }
                override fun onStopped() { if (generation == run) { stopSharing(); status.text = "Hotspot stopped." } }
            }, Handler(Looper.getMainLooper()))
        } catch (e: SecurityException) {
            stopSharing(); status.text = "Hotspot permission was denied or revoked. Allow the requested permission, then retry."
        } catch (e: Exception) { stopSharing(); status.text = "Could not start hotspot: ${e.message}" }
    }

    private fun qrBitmap(payload: String): Bitmap {
        val matrix = MultiFormatWriter().encode(payload, BarcodeFormat.QR_CODE, 800, 800)
        val pixels = IntArray(800 * 800) { i -> if (matrix[i % 800, i / 800]) 0xff000000.toInt() else 0xffffffff.toInt() }
        return Bitmap.createBitmap(pixels, 800, 800, Bitmap.Config.ARGB_8888)
    }

    private fun showCode(wifi: Boolean) {
        qr.setImageBitmap(if (wifi) wifiBitmap else pairingBitmap)
        qr.contentDescription = if (wifi) "Wi-Fi connection QR code" else "Nearby secure pairing QR code"
        qrHelp.text = if (wifi)
            "Step 1: Open the iPhone's Camera (outside Nearby), scan this Wi-Fi code, and tap Join Network. Stay connected without internet. Then tap step 2 above. If Camera does not offer to join, use the Settings instructions after scanning the Nearby code."
        else "Step 2: Open Nearby on the iPhone and tap Scan Android pairing code. Scan this code, then tap Inspect current connection. Already on the same Wi-Fi? You can skip step 1, though the direct hotspot was faster in device testing."
    }

    private fun stopSharing() {
        generation++; pending = null
        server?.stop(); server = null
        val old = reservation; reservation = null; old?.close()
        selected?.delete(); selected = null
        if (::qr.isInitialized) qr.setImageDrawable(null)
        wifiBitmap = null; pairingBitmap = null
        if (::qrSteps.isInitialized) qrSteps.visibility = android.view.View.GONE
        if (::qrHelp.isInitialized) qrHelp.text = ""
        if (::choose.isInitialized) choose.isEnabled = true
        if (::status.isInitialized) status.text = "Sharing stopped. Previous QR code is invalid."
    }

    override fun onDestroy() { stopSharing(); worker.shutdown(); super.onDestroy() }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}
