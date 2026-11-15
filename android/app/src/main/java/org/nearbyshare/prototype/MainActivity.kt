package org.nearbyshare.prototype

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.os.IBinder
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.content.res.ColorStateList
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
    private var selected: File? = null
    @Volatile private var generation = 0
    private val inbox: ReceiveInbox? get() = shareService?.inbox
    private lateinit var receiveButton: Button
    private lateinit var acceptButton: Button
    private lateinit var rejectButton: Button
    private lateinit var saveButton: Button
    private var exportFile: File? = null
    private var displayedOfferID: String? = null
    private val savedOutgoing by lazy { SavedOutgoingFiles(File(filesDir, "saved-outgoing")) }
    private lateinit var shareLast: Button
    private lateinit var savedShares: Button
    private lateinit var forgetShares: Button
    private lateinit var savedShareInfo: TextView

    private var shareService: ShareSessionService? = null
    private var bound = false
    private var shownPairing: String? = null
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            shareService = (binder as ShareSessionService.LocalBinder).service
            shareService?.listener = { renderSession() }
            renderSession()
        }
        override fun onServiceDisconnected(name: ComponentName) {
            shareService = null
            status.text = "Sharing service stopped. Use a saved file to reconnect."
        }
    }
    private fun renderSession() {
        val service = shareService ?: return
        status.text = service.message
        val code = service.pairingCode
        if (code != shownPairing) {
            shownPairing = code
            pairingBitmap = code?.let { qrBitmap(it) }
            wifiBitmap = service.wifiCode?.let { qrBitmap(it) }
            qrSteps.visibility = if (code == null) android.view.View.GONE else android.view.View.VISIBLE
            if (code != null) showCode(wifi = true) else { qr.setImageDrawable(null); qrHelp.text = "" }
        }
        if (service.inbox?.snapshot() != null) renderIncoming()
        else { acceptButton.visibility = android.view.View.GONE; rejectButton.visibility = android.view.View.GONE; saveButton.visibility = android.view.View.GONE }
        if (!service.active) { choose.isEnabled = true; receiveButton.isEnabled = true }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val ink = Color.rgb(22, 38, 61)
        val blue = Color.rgb(28, 79, 240)
        window.statusBarColor = Color.rgb(244, 247, 250)
        window.navigationBarColor = Color.rgb(244, 247, 250)
        window.decorView.systemUiVisibility = android.view.View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or android.view.View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(20), dp(20), dp(28))
            setBackgroundColor(Color.rgb(244, 247, 250))
        }
        layout.addView(TextView(this).apply { text = "nearby."; textSize = 32f; setTextColor(ink); setTypeface(null, Typeface.BOLD) })
        layout.addView(TextView(this).apply {
            text = "Across the room."; textSize = 23f; setTextColor(ink); setTypeface(null, Typeface.BOLD)
            setPadding(0, dp(20), 0, dp(5))
        })
        layout.addView(TextView(this).apply { text = "Directly between your devices."; textSize = 15f; setTextColor(Color.rgb(84, 102, 122)) })
        layout.addView(TextView(this).apply {
            text = "SHARE OFFLINE\n\nAndroid  ↔  iPhone\n\nChoose a file. Connect. Send."
            textSize = 19f; setTextColor(Color.WHITE); setPadding(dp(24), dp(24), dp(24), dp(24))
            background = rounded(blue, 28)
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin=dp(24); bottomMargin=dp(18) })
        choose = Button(this).apply {
            text = "Choose a file"
            setOnClickListener { startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                type = "*/*"; addCategory(Intent.CATEGORY_OPENABLE)
            }, 10) }
        }
        choose.setTextColor(Color.WHITE)
        choose.backgroundTintList = ColorStateList.valueOf(blue)
        choose.isAllCaps = false
        choose.textSize = 17f
        choose.minHeight = dp(58)
        layout.addView(choose, LinearLayout.LayoutParams(-1, -2))
        receiveButton = Button(this).apply {
            text = "Receive from iPhone"
            setOnClickListener {
                stopSharing(); choose.isEnabled = false; isEnabled = false
                startWithPermission("", null, "")
            }
        }
        layout.addView(receiveButton)
        shareLast = Button(this).apply {
            text = "Share last file again"
            setOnClickListener { savedOutgoing.all().firstOrNull()?.let { restartSavedShare(it) } }
        }
        savedShares = Button(this).apply {
            text = "Saved shared files"
            setOnClickListener {
                val items = savedOutgoing.all()
                if (items.isEmpty()) { refreshSavedShares(); return@setOnClickListener }
                android.app.AlertDialog.Builder(this@MainActivity).setTitle("Share a saved file again")
                    .setItems(items.map { "${it.name} (${android.text.format.Formatter.formatShortFileSize(this@MainActivity, it.size)})" }.toTypedArray()) { _, index -> restartSavedShare(items[index]) }
                    .setNegativeButton("Close", null).show()
            }
        }
        forgetShares = Button(this).apply {
            text = "Forget saved shared files"
            setOnClickListener {
                android.app.AlertDialog.Builder(this@MainActivity).setTitle("Forget saved shared files?")
                    .setMessage("This stops the current session and deletes Nearby's saved outgoing copies. Original files and received files remain.")
                    .setPositiveButton("Forget") { _, _ -> stopSharing(); savedOutgoing.forgetAll(); refreshSavedShares() }
                    .setNegativeButton("Keep", null).show()
            }
        }
        savedShareInfo = TextView(this).apply { textSize = 13f; setTextColor(ink) }
        layout.addView(shareLast); layout.addView(savedShares); layout.addView(forgetShares); layout.addView(savedShareInfo)
        acceptButton = Button(this).apply { text = "Accept incoming file"; visibility = android.view.View.GONE; setOnClickListener { displayedOfferID?.let { inbox?.decide(it, true) } } }
        rejectButton = Button(this).apply { text = "Reject incoming file"; visibility = android.view.View.GONE; setOnClickListener { displayedOfferID?.let { inbox?.decide(it, false) } } }
        saveButton = Button(this).apply {
            text = "Save received file…"; visibility = android.view.View.GONE
            setOnClickListener {
                val item = inbox?.snapshot() ?: return@setOnClickListener
                exportFile = item.saved ?: return@setOnClickListener
                startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    type = "application/octet-stream"; addCategory(Intent.CATEGORY_OPENABLE)
                    putExtra(Intent.EXTRA_TITLE, item.name.replace(Regex("[/\\\\]"), "_").take(120))
                }, 11)
            }
        }
        layout.addView(acceptButton); layout.addView(rejectButton); layout.addView(saveButton)
        layout.addView(Button(this).apply {
            text = "Saved incoming files"
            setOnClickListener {
                val files = File(filesDir, "received").listFiles()?.filter { it.extension == "received" }?.sortedByDescending { it.lastModified() }.orEmpty()
                val names = files.map { file ->
                    try { JSONObject(File(file.parentFile, "${file.nameWithoutExtension}.json").readText()).getString("name") }
                    catch (_: Exception) { "Received file" }
                }
                if (files.isEmpty()) { status.text = "No incoming files saved yet."; return@setOnClickListener }
                android.app.AlertDialog.Builder(this@MainActivity).setTitle("Save a verified file")
                    .setItems(names.toTypedArray()) { _, index ->
                        exportFile = files[index]
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            type = "application/octet-stream"; addCategory(Intent.CATEGORY_OPENABLE)
                            putExtra(Intent.EXTRA_TITLE, names[index].replace('/', '_').replace('\\', '_').take(120))
                        }, 11)
                    }.setNegativeButton("Close", null).show()
            }
        })
        layout.addView(Button(this).apply { text = "Stop sharing"; setOnClickListener { stopSharing() } })
        status = TextView(this).apply {
            text = "Ready. No internet needed."; textSize = 16f; setTextColor(ink)
            setPadding(dp(18), dp(18), dp(18), dp(18)); background = rounded(Color.WHITE, 22)
            accessibilityLiveRegion = android.view.View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
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
        qrHelp = TextView(this).apply {
            textSize = 15f; setTextColor(ink); setPadding(0, dp(16), 0, dp(12))
        }
        layout.addView(qrHelp)
        qr = ImageView(this).apply {
            adjustViewBounds = true; scaleType = ImageView.ScaleType.FIT_CENTER
            setBackgroundColor(Color.WHITE)
        }
        layout.addView(qr, LinearLayout.LayoutParams(-1, -2))
        layout.addView(TextView(this).apply {
            text = "Android stays active through its transfer notification. On iPhone, follow the displayed background status. Anyone scanning the pairing code can request a transfer. Sending mode shares your selected file; receiving mode asks before accepting.\n\nNearby 0.4.0 · Android ↔ iPhone"
            textSize = 13f; setTextColor(Color.rgb(84, 102, 122)); setPadding(0, dp(20), 0, 0)
        })
        setContentView(ScrollView(this).apply { addView(layout) })
        refreshSavedShares()
        bound = bindService(Intent(this, ShareSessionService::class.java), connection, Context.BIND_AUTO_CREATE)
    }

    @Deprecated("Prototype uses platform picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 11 && resultCode == RESULT_OK) {
            val source = exportFile ?: return
            val destination = data?.data ?: return
            worker.execute {
                try {
                    contentResolver.openOutputStream(destination, "w")!!.use { output -> source.inputStream().use { it.copyTo(output, 262144) } }
                    runOnUiThread { status.text = "Saved your verified file to the selected location." }
                } catch (_: Exception) {
                    runOnUiThread { status.text = "Could not export the file. The verified original remains in Nearby; try Save again." }
                }
            }
            return
        }
        if (requestCode != 10 || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        stopSharing()
        val run = generation
        choose.isEnabled = false; receiveButton.isEnabled = false
        status.text = "Preparing file and integrity checksum…"
        worker.execute {
            var snapshot: File? = null
            try {
                var name = "Shared file"
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                    if (it.moveToFirst()) {
                        name = it.getString(0) ?: name
                        if (!it.isNull(1)) require(it.getLong(1) <= cacheDir.usableSpace - ReceiveInbox.RESERVE) { "Not enough free storage to prepare this file." }
                    }
                }
                // Snapshot avoids a provider changing bytes between hashing and downloading.
                val file = File.createTempFile("outgoing-", ".bin", cacheDir)
                snapshot = file
                val hash = MessageDigest.getInstance("SHA-256")
                contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().buffered(262144).use { output ->
                    val buffer = ByteArray(262144)
                    while (true) {
                        check(generation == run) { "Preparation cancelled" }
                        check(cacheDir.usableSpace > ReceiveInbox.RESERVE) { "Not enough free storage to prepare this file." }
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count); hash.update(buffer, 0, count)
                    }
                } }
                val digest = hex(hash.digest())
                val remembered = savedOutgoing.remember(file, name, digest) { generation == run }
                runOnUiThread {
                    refreshSavedShares()
                    if (generation == run && !isDestroyed) {
                        selected = remembered.file; startWithPermission(remembered.name, remembered.file, remembered.hash)
                    }
                }
            } catch (e: Exception) {
                snapshot?.delete()
                runOnUiThread { if (generation == run) { choose.isEnabled = true; receiveButton.isEnabled = true; status.text = "Preparation failed: ${e.message}" } }
            }
        }
    }

    private var pending: (() -> Unit)? = null
    private fun startWithPermission(name: String, file: File?, hash: String) {
        val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
        if (checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
            pending = { startWithPermission(name, file, hash) }
            val permissions = if (Build.VERSION.SDK_INT >= 33) arrayOf(permission)
                else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
            requestPermissions(permissions, 20)
        } else if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            pending = { startHotspot(name,file,hash) }
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),21)
        } else startHotspot(name, file, hash)
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        val action = pending; pending = null
        if (code == 21) action?.invoke()
        else if (code == 20 && results.firstOrNull() == PackageManager.PERMISSION_GRANTED) action?.invoke()
        else if (code == 20) { status.text = "Permission required to create the temporary connection."; choose.isEnabled = true; receiveButton.isEnabled = true }
    }

    private fun startHotspot(name: String, file: File?, hash: String) {
        val service = shareService
        if (service == null) {
            choose.isEnabled = true; receiveButton.isEnabled = true
            status.text = "Nearby is still starting. Try again in a moment."
            return
        }
        service.startSharing(name,file,hash)
        renderSession()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density + 0.5f).toInt()
    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat()
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
        displayedOfferID = null
        shareService?.stopSharing()
        shownPairing = null
        selected = null // Saved private snapshots survive stopping/reopening; Forget deletes them.
        if (::qr.isInitialized) qr.setImageDrawable(null)
        wifiBitmap = null; pairingBitmap = null
        if (::qrSteps.isInitialized) qrSteps.visibility = android.view.View.GONE
        if (::qrHelp.isInitialized) qrHelp.text = ""
        if (::choose.isInitialized) choose.isEnabled = true
        if (::receiveButton.isInitialized) receiveButton.isEnabled = true
        if (::acceptButton.isInitialized) acceptButton.visibility = android.view.View.GONE
        if (::rejectButton.isInitialized) rejectButton.visibility = android.view.View.GONE
        if (::saveButton.isInitialized) saveButton.visibility = android.view.View.GONE
        if (::status.isInitialized) status.text = "Sharing stopped. Previous QR code is invalid. Saved files can be shared again without the picker."
        if (::shareLast.isInitialized) refreshSavedShares()
    }

    private fun refreshSavedShares() {
        val items = savedOutgoing.all()
        shareLast.isEnabled = items.isNotEmpty(); savedShares.isEnabled = items.isNotEmpty(); forgetShares.isEnabled = items.isNotEmpty()
        savedShareInfo.text = if (items.isEmpty()) "Nearby remembers up to 3 selected files privately for reconnecting."
        else "${items.size} saved outgoing file(s), ${android.text.format.Formatter.formatShortFileSize(this, items.sumOf { it.size })}. Copies stay in Nearby until replaced by newer selections or forgotten."
    }

    private fun restartSavedShare(item: SavedOutgoingFiles.Item) {
        stopSharing()
        val run = generation
        choose.isEnabled = false; receiveButton.isEnabled = false
        status.text = "Checking saved file before sharing again…"
        worker.execute {
            try {
                val current = savedOutgoing.all().firstOrNull { it.id == item.id } ?: error("Saved file is unavailable. Choose it again.")
                val digest = MessageDigest.getInstance("SHA-256")
                current.file.inputStream().buffered(262144).use { input ->
                    val buffer = ByteArray(262144)
                    while (true) {
                        check(generation == run) { "Restart cancelled" }
                        val count = input.read(buffer); if (count < 0) break
                        digest.update(buffer, 0, count)
                    }
                }
                check(hex(digest.digest()) == current.hash) { "Saved copy changed. Choose the original file again." }
                runOnUiThread { if (generation == run && !isDestroyed) {
                    selected = current.file; startWithPermission(current.name, current.file, current.hash)
                } }
            } catch (error: Exception) {
                runOnUiThread { if (generation == run && !isDestroyed) {
                    choose.isEnabled = true; receiveButton.isEnabled = true; refreshSavedShares()
                    status.text = "Could not restart sharing: ${error.message}"
                } }
            }
        }
    }

    private fun renderIncoming() {
        val item = inbox?.snapshot() ?: return
        displayedOfferID = item.id
        acceptButton.visibility = if (item.state == "waiting") android.view.View.VISIBLE else android.view.View.GONE
        rejectButton.visibility = acceptButton.visibility
        saveButton.visibility = if (item.state == "complete") android.view.View.VISIBLE else android.view.View.GONE
        status.text = when (item.state) {
            "waiting" -> "iPhone offers ${item.name} (${item.size} bytes). Accept only if this is the file you expect."
            "accepted" -> "Accepted. Waiting for iPhone to send…"
            "receiving" -> "Receiving ${item.name}: ${item.bytes} / ${item.size} bytes"
            "complete" -> "Verified complete: ${item.name}. Tap Save received file to choose where to keep it."
            "failed" -> "Receive failed: ${item.error}. No incomplete file was kept."
            else -> "Transfer ${item.state}. You can choose another file on the iPhone."
        }
    }

    override fun onDestroy() {
        generation++ // Cancel only Activity-owned preparation, never the service's active session.
        shareService?.listener = null
        if (bound) { unbindService(connection); bound = false }
        shareService = null; worker.shutdown(); super.onDestroy()
    }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
}
