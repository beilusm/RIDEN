package io.github.beilusm.ridenps

import com.fazecast.jSerialComm.SerialPort
import io.github.beilusm.ridenps.core.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import javax.swing.JFileChooser
import javax.swing.JOptionPane
import javax.swing.filechooser.FileNameExtensionFilter

class DesktopTransport : SerialTransport {
    private var port: SerialPort? = null
    override suspend fun devices(): List<SerialDevice> = withContext(Dispatchers.IO) {
        SerialPort.getCommPorts().map { SerialDevice(it.systemPortPath, "${it.systemPortName} · ${it.descriptivePortName}", it.vendorID == 0x1a86) }
    }
    override suspend fun open(device: SerialDevice, config: SerialConfig) = withContext(Dispatchers.IO) {
        val serial = SerialPort.getCommPort(device.id)
        serial.setComPortParameters(config.baud, 8, SerialPort.ONE_STOP_BIT, SerialPort.NO_PARITY)
        serial.setFlowControl(SerialPort.FLOW_CONTROL_DISABLED)
        check(serial.openPort()) { "Cannot open ${device.id}. Check serial permissions." }
        port = serial
        serial.flushIOBuffers()
        Unit
    }
    override suspend fun write(bytes: ByteArray) = withContext(Dispatchers.IO) {
        val serial = checkNotNull(port) { "Serial disconnected" }
        serial.setComPortTimeouts(SerialPort.TIMEOUT_WRITE_BLOCKING, 25, 250)
        check(serial.writeBytes(bytes, bytes.size) == bytes.size) { "Serial write failed" }
    }
    override suspend fun read(maxBytes: Int, timeoutMs: Int): ByteArray = withContext(Dispatchers.IO) {
        val serial = checkNotNull(port) { "Serial disconnected" }
        serial.setComPortTimeouts(SerialPort.TIMEOUT_READ_SEMI_BLOCKING, timeoutMs.coerceAtLeast(1), 250)
        val buffer = ByteArray(maxBytes)
        val size = serial.readBytes(buffer, buffer.size)
        check(size >= 0) { "Serial device removed" }
        buffer.copyOf(size)
    }
    override suspend fun close() = withContext(Dispatchers.IO) { port?.closePort(); port = null }
}

class DesktopServices : PlatformServices {
    override val transport = DesktopTransport()
    private suspend fun choose(name: String): File? = withContext(Dispatchers.Main) {
        val chooser = JFileChooser().apply {
            dialogTitle = "Save CSV"
            selectedFile = File(name)
            fileFilter = FileNameExtensionFilter("CSV (*.csv)", "csv")
        }
        if (chooser.showSaveDialog(null) != JFileChooser.APPROVE_OPTION) return@withContext null
        val file = chooser.selectedFile
        if (file.exists() && JOptionPane.showConfirmDialog(null, "Replace ${file.name}?", "Save CSV", JOptionPane.YES_NO_OPTION, JOptionPane.WARNING_MESSAGE) != JOptionPane.YES_OPTION) return@withContext null
        file
    }
    override suspend fun startRecording(): RecordingSink? {
        val file = choose("riden-${System.currentTimeMillis()}.csv") ?: return null
        val writer = withContext(Dispatchers.IO) { file.bufferedWriter() }
        return object : RecordingSink {
            override suspend fun append(line: String) = withContext(Dispatchers.IO) { writer.appendLine(line); Unit }
            override suspend fun finish(export: Boolean): String = withContext(Dispatchers.IO) { writer.close(); file.absolutePath }
        }
    }
    override suspend fun exportText(name: String, text: String): String? {
        val file = choose(name) ?: return null
        return withContext(Dispatchers.IO) { file.writeText(text); file.absolutePath }
    }
}
