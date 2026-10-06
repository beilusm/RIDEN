package io.github.beilusm.ridenps

import android.app.PendingIntent
import android.content.*
import android.hardware.usb.UsbManager
import android.os.Build
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import io.github.beilusm.ridenps.core.*
import kotlinx.coroutines.*
import java.io.File
import kotlin.coroutines.resume

class AndroidTransport(private val context: Context) : SerialTransport {
    private val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private var port: UsbSerialPort? = null
    private var connection: android.hardware.usb.UsbDeviceConnection? = null
    override suspend fun devices(): List<SerialDevice> = withContext(Dispatchers.IO) {
        UsbSerialProber.getDefaultProber().findAllDrivers(manager).map {
            SerialDevice(it.device.deviceName, "USB ${it.device.vendorId.toString(16)}:${it.device.productId.toString(16)}", it.device.vendorId == 0x1a86)
        }
    }
    override suspend fun open(device: SerialDevice, config: SerialConfig) {
        val driver = withContext(Dispatchers.IO) { UsbSerialProber.getDefaultProber().findAllDrivers(manager).firstOrNull { it.device.deviceName == device.id } } ?: error("USB device removed")
        if (!manager.hasPermission(driver.device)) {
            val granted = withTimeout(30000) { suspendCancellableCoroutine<Boolean> { continuation ->
                val action = "${context.packageName}.USB_PERMISSION"
                val receiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        if (intent.action == action && continuation.isActive) {
                            runCatching { context.unregisterReceiver(this) }
                            continuation.resume(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
                        }
                    }
                }
                if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_NOT_EXPORTED)
                else @Suppress("DEPRECATION") context.registerReceiver(receiver, IntentFilter(action))
                continuation.invokeOnCancellation { runCatching { context.unregisterReceiver(receiver) } }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                manager.requestPermission(driver.device, PendingIntent.getBroadcast(context, 0, Intent(action).setPackage(context.packageName), flags))
            } }
            check(granted) { "USB permission denied" }
        }
        withContext(Dispatchers.IO) {
            val conn = manager.openDevice(driver.device) ?: error("Cannot open USB device")
            connection = conn
            val serial = driver.ports.first()
            port = serial
            try {
                serial.open(conn)
                serial.setParameters(config.baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
                serial.dtr = true; serial.rts = true
                serial.purgeHwBuffers(true, true)
            } catch (e: Exception) { runCatching { serial.close() }; conn.close(); port = null; connection = null; throw e }
        }
    }
    override suspend fun write(bytes: ByteArray) = withContext(Dispatchers.IO) { checkNotNull(port).write(bytes, 250) }
    override suspend fun read(maxBytes: Int, timeoutMs: Int): ByteArray = withContext(Dispatchers.IO) {
        val bytes = ByteArray(maxBytes)
        bytes.copyOf(checkNotNull(port).read(bytes, timeoutMs.coerceAtLeast(1)))
    }
    override suspend fun close() = withContext(Dispatchers.IO) {
        try { port?.close() } finally { connection?.close(); port = null; connection = null }
        Unit
    }
}

class AndroidServices(private val context: Context, private val save: suspend (String, File) -> String?) : PlatformServices {
    override val transport = AndroidTransport(context)
    override suspend fun startRecording(): RecordingSink {
        val file = withContext(Dispatchers.IO) { File.createTempFile("riden-", ".csv", context.filesDir) }
        val writer = withContext(Dispatchers.IO) { file.bufferedWriter() }
        return object : RecordingSink {
            override suspend fun append(line: String) = withContext(Dispatchers.IO) { writer.appendLine(line); Unit }
            override suspend fun finish(export: Boolean): String {
                withContext(Dispatchers.IO) { writer.close() }
                val saved = if (export) save(file.name, file) else null
                if (saved != null) { withContext(Dispatchers.IO) { file.delete() }; return saved }
                return "Saved privately: ${file.absolutePath}"
            }
        }
    }
    override suspend fun exportText(name: String, text: String): String? {
        val file = withContext(Dispatchers.IO) { File.createTempFile("registers-", ".csv", context.filesDir).apply { writeText(text) } }
        val saved = save(name, file)
        if (saved != null) withContext(Dispatchers.IO) { file.delete() }
        return saved ?: file.absolutePath
    }
}
