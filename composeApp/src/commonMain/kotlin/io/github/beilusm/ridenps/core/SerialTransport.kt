package io.github.beilusm.ridenps.core

data class SerialDevice(val id: String, val label: String, val preferred: Boolean = false)
data class SerialConfig(val baud: Int = 115200, val address: Int = 1) {
    init { require(baud > 0 && address in 1..247) }
}

interface SerialTransport {
    suspend fun devices(): List<SerialDevice>
    suspend fun open(device: SerialDevice, config: SerialConfig)
    suspend fun write(bytes: ByteArray)
    suspend fun read(maxBytes: Int, timeoutMs: Int): ByteArray
    suspend fun close()
}

interface RecordingSink {
    suspend fun append(line: String)
    suspend fun finish(export: Boolean = true): String
}

interface PlatformServices {
    val transport: SerialTransport
    suspend fun startRecording(): RecordingSink?
    suspend fun exportText(name: String, text: String): String?
}
