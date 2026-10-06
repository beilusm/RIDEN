package io.github.beilusm.ridenps.core

import kotlinx.coroutines.delay
import kotlinx.datetime.Clock
import kotlin.math.sin
import kotlin.math.roundToInt

class DemoTransport(model: Int = 6006) : SerialTransport {
    private var open = false
    private var response = byteArrayOf()
    private val capabilities = DeviceCapabilities.fromModel(model) ?: requireNotNull(DeviceCapabilities.fromModel(6006))
    private val registers = IntArray(121).apply {
        this[0] = model; this[3] = 120; this[5] = 31; this[14] = 4800
        this[8] = (12.0 * capabilities.voltageScale).toInt(); this[9] = (1.5 * capabilities.currentScale).toInt()
        repeat(10) { slot ->
            this[80 + slot * 4] = ((5.0 + slot * 2.5) * capabilities.voltageScale).toInt()
            this[81 + slot * 4] = capabilities.currentScale
            this[82 + slot * 4] = (capabilities.maxOvp * capabilities.voltageScale).roundToInt()
            this[83 + slot * 4] = (capabilities.maxOcp * capabilities.currentScale).roundToInt()
        }
    }
    override suspend fun devices() = listOf(SerialDevice("demo", "Demo"))
    override suspend fun open(device: SerialDevice, config: SerialConfig) { open = true }
    override suspend fun close() { open = false; response = byteArrayOf() }
    override suspend fun write(bytes: ByteArray) {
        check(open)
        val start = (bytes[2].toInt() and 255) * 256 + (bytes[3].toInt() and 255)
        val value = (bytes[4].toInt() and 255) * 256 + (bytes[5].toInt() and 255)
        if (bytes[1].toInt() == 6) {
            registers[start] = value
            if (start == 19 && value in 1..9) {
                registers[8] = registers[80 + value * 4]; registers[9] = registers[81 + value * 4]
            }
            response = bytes.copyOf()
        } else {
            val ripple = sin(Clock.System.now().toEpochMilliseconds() / 1400.0)
            registers[10] = if (registers[18] == 1) registers[8] + (ripple * 3).toInt() else 0
            registers[11] = if (registers[18] == 1) (registers[9] * (0.65 + ripple * 0.04)).toInt() else 0
            val data = ByteArray(5 + value * 2)
            data[0] = bytes[0]; data[1] = 3; data[2] = (value * 2).toByte()
            repeat(value) { i -> data[3 + i * 2] = (registers[start + i] ushr 8).toByte(); data[4 + i * 2] = registers[start + i].toByte() }
            val crc = RtuCodec.crc(data, data.size - 2)
            data[data.size - 2] = crc.toByte(); data[data.size - 1] = (crc ushr 8).toByte()
            response = data
        }
    }
    override suspend fun read(maxBytes: Int, timeoutMs: Int): ByteArray {
        delay(3)
        val data = response.take(maxBytes).toByteArray()
        response = response.drop(data.size).toByteArray()
        return data
    }
}
