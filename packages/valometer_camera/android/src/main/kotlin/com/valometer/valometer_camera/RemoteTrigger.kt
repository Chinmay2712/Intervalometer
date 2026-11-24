package com.valometer.valometer_camera

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Turns this phone into a Bluetooth keyboard (HID device) that sends
 * "Volume Up", which the iPhone Camera app treats as the shutter button,
 * the same trick cheap Bluetooth selfie remotes use.
 *
 * Channel "valometer/remote". Connection changes are pushed to Dart as
 * "state" calls: {state, name, address}.
 */
@SuppressLint("MissingPermission") // every entry point checks [hasPermissions] first
class RemoteTrigger(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "valometer/remote")
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val adapter: BluetoothAdapter? =
        context.getSystemService(BluetoothManager::class.java)?.adapter

    var activity: Activity? = null

    private var hid: BluetoothHidDevice? = null
    private var registered = false
    private var host: BluetoothDevice? = null
    private var connecting: BluetoothDevice? = null
    private var pendingStart: MethodChannel.Result? = null
    private var pendingPermission: ((Boolean) -> Unit)? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        stop()
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "start" -> withPermissions(result) { start(result) }
            "enableBluetooth" -> withPermissions(result) {
                activity?.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), ENABLE_REQUEST)
                result.success(null)
            }
            "makeDiscoverable" -> withPermissions(result) {
                val intent = Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
                    .putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 120)
                activity?.startActivityForResult(intent, DISCOVERABLE_REQUEST)
                result.success(adapter?.name)
            }
            "pairedDevices" -> withPermissions(result) {
                result.success(adapter?.bondedDevices.orEmpty().map {
                    mapOf("name" to (it.name ?: it.address), "address" to it.address)
                })
            }
            "connect" -> withPermissions(result) {
                val address = call.argument<String>("address")
                val h = hid
                if (address == null || h == null || !registered) {
                    result.error("not_ready", "The remote isn't running yet.", null)
                } else {
                    val device = adapter?.getRemoteDevice(address)
                    connecting = device
                    result.success(device != null && h.connect(device))
                    emit(STATE_CONNECTING, device)
                }
            }
            "disconnect" -> {
                host?.let { d -> if (hasPermissions()) hid?.disconnect(d) }
                result.success(null)
            }
            "press" -> result.success(press())
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------- state

    private fun status(): Map<String, Any?> = mapOf(
        "bluetooth" to (adapter != null),
        "enabled" to (adapter?.isEnabled == true),
        "permission" to hasPermissions(),
        "registered" to registered,
        "state" to (if (host != null) STATE_CONNECTED else STATE_DISCONNECTED),
        "name" to host?.let { safeName(it) },
        "address" to host?.address,
        "phoneName" to if (hasPermissions()) adapter?.name else null,
    )

    private fun emit(state: String, device: BluetoothDevice?) {
        val args = mapOf(
            "state" to state,
            "name" to device?.let { safeName(it) },
            "address" to device?.address,
        )
        main.post { channel.invokeMethod("state", args) }
    }

    private fun safeName(d: BluetoothDevice): String =
        (if (hasPermissions()) d.name else null) ?: d.address

    // ---------------------------------------------------------------- HID

    private fun start(result: MethodChannel.Result) {
        val a = adapter ?: return result.error("no_bluetooth", "This phone has no Bluetooth.", null)
        if (!a.isEnabled) return result.error("bluetooth_off", "Bluetooth is off.", null)
        if (registered) return result.success(status())
        pendingStart = result
        val asked = a.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                hid = proxy as BluetoothHidDevice
                val ok = hid?.registerApp(sdp, null, null, executor, callback) == true
                if (!ok) failStart("unsupported", "This phone can't act as a Bluetooth keyboard.")
            }

            override fun onServiceDisconnected(profile: Int) {
                hid = null
                registered = false
                host = null
                emit(STATE_DISCONNECTED, null)
            }
        }, BluetoothProfile.HID_DEVICE)
        if (!asked) return failStart("unsupported", "This phone can't act as a Bluetooth keyboard.")
        // Some phone makers remove the keyboard profile; then nothing answers.
        main.postDelayed({
            if (pendingStart != null) failStart("unsupported", "This phone can't act as a Bluetooth keyboard (the maker disabled it).")
        }, 5000)
    }

    private fun failStart(code: String, message: String) {
        val r = pendingStart ?: return
        pendingStart = null
        main.post { r.error(code, message, null) }
    }

    private val callback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
            this@RemoteTrigger.registered = registered
            pendingStart?.let { r ->
                pendingStart = null
                main.post { if (registered) r.success(status()) else r.error("unsupported", "Couldn't start the remote.", null) }
            }
            // Reconnect to the last iPhone automatically.
            if (registered && pluggedDevice != null && host == null) hid?.connect(pluggedDevice)
            if (!registered) {
                host = null
                emit(STATE_DISCONNECTED, null)
            }
        }

        override fun onConnectionStateChanged(device: BluetoothDevice, state: Int) {
            when (state) {
                BluetoothProfile.STATE_CONNECTED -> {
                    host = device
                    connecting = null
                    emit(STATE_CONNECTED, device)
                }
                BluetoothProfile.STATE_CONNECTING -> emit(STATE_CONNECTING, device)
                BluetoothProfile.STATE_DISCONNECTED -> {
                    if (host?.address == device.address) host = null
                    if (connecting?.address == device.address) connecting = null
                    emit(if (host != null) STATE_CONNECTED else STATE_DISCONNECTED, host ?: device)
                }
            }
        }

        override fun onGetReport(device: BluetoothDevice, type: Byte, id: Byte, bufferSize: Int) {
            val size = if (id.toInt() == KEYBOARD_REPORT) 8 else 1
            hid?.replyReport(device, type, id, ByteArray(size))
        }
    }

    /** One short "Volume Up" press = one photo. A long hold would start video. */
    private fun press(): Boolean {
        val d = host ?: return false
        val h = hid ?: return false
        if (!hasPermissions()) return false
        if (!h.sendReport(d, CONSUMER_REPORT, byteArrayOf(VOLUME_UP))) return false
        main.postDelayed({ if (hasPermissions()) h.sendReport(d, CONSUMER_REPORT, byteArrayOf(0)) }, 80)
        return true
    }

    private fun stop() {
        pendingStart = null
        if (hasPermissions()) {
            host?.let { hid?.disconnect(it) }
            if (registered) hid?.unregisterApp()
        }
        hid?.let { adapter?.closeProfileProxy(BluetoothProfile.HID_DEVICE, it) }
        hid = null
        registered = false
        host = null
    }

    // ---------------------------------------------------------------- permissions

    private val permissions: Array<String>
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        } else {
            emptyArray() // install-time BLUETOOTH / BLUETOOTH_ADMIN before Android 12
        }

    private fun hasPermissions() = permissions.all {
        context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }

    private fun withPermissions(result: MethodChannel.Result, body: () -> Unit) {
        if (hasPermissions()) return body()
        val a = activity ?: return result.error("permission", "Nearby devices permission is needed.", null)
        pendingPermission = { granted ->
            if (granted) body()
            else result.error("permission", "Allow \"Nearby devices\" in Settings › Apps › Valometer › Permissions.", null)
        }
        a.requestPermissions(permissions, PERMISSION_REQUEST)
    }

    /** Forwarded from the plugin. Returns true if it was ours. */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        pending(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        return true
    }

    companion object {
        const val PERMISSION_REQUEST = 4208
        private const val ENABLE_REQUEST = 4209
        private const val DISCOVERABLE_REQUEST = 4210
        private const val CONSUMER_REPORT = 1
        private const val KEYBOARD_REPORT = 2
        private const val VOLUME_UP: Byte = 0x01
        private const val STATE_CONNECTED = "connected"
        private const val STATE_CONNECTING = "connecting"
        private const val STATE_DISCONNECTED = "disconnected"

        /** A media-key collection (Volume Up/Down) plus a plain keyboard, like selfie remotes. */
        private val descriptor = intArrayOf(
            // Consumer control, report 1: bit 0 = Volume Up, bit 1 = Volume Down
            0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, CONSUMER_REPORT,
            0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x02,
            0x09, 0xE9, 0x09, 0xEA, 0x81, 0x02,
            0x95, 0x06, 0x81, 0x01,
            0xC0,
            // Keyboard, report 2 (never pressed; makes iOS accept the device as a keyboard)
            0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, KEYBOARD_REPORT,
            0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
            0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
            0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
            0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
            0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
            0xC0,
        ).map { it.toByte() }.toByteArray()

        private val sdp = BluetoothHidDeviceAppSdpSettings(
            "Valometer Remote",
            "Camera shutter remote",
            "Valometer",
            BluetoothHidDevice.SUBCLASS1_COMBO,
            descriptor,
        )
    }
}
