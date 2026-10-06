package io.github.beilusm.ridenps.core

import kotlinx.coroutines.CancellationException
import kotlin.time.TimeSource

class ModbusException(message: String) : Exception(message)

object RtuCodec {
    fun crc(bytes: ByteArray, count: Int = bytes.size): Int {
        var crc = 0xffff
        for (i in 0 until count) {
            crc = crc xor (bytes[i].toInt() and 255)
            repeat(8) { crc = if (crc and 1 != 0) (crc ushr 1) xor 0xa001 else crc ushr 1 }
        }
        return crc
    }
    fun frame(address: Int, function: Int, register: Int, value: Int): ByteArray {
        val frame = byteArrayOf(address.toByte(), function.toByte(), (register ushr 8).toByte(), register.toByte(), (value ushr 8).toByte(), value.toByte(), 0, 0)
        val crc = crc(frame, 6)
        frame[6] = crc.toByte(); frame[7] = (crc ushr 8).toByte()
        return frame
    }
    fun validate(frame: ByteArray, address: Int, function: Int) {
        if (frame.size < 5) throw ModbusException("Incomplete response")
        val crc = crc(frame, frame.size - 2)
        if ((frame[frame.size - 2].toInt() and 255) != crc and 255 || (frame.last().toInt() and 255) != crc ushr 8)
            throw ModbusException("CRC mismatch")
        if ((frame[0].toInt() and 255) != address) throw ModbusException("Wrong slave address")
        val actual = frame[1].toInt() and 255
        if (actual == function or 0x80) throw ModbusException("Device exception ${frame[2].toInt() and 255}")
        if (actual != function) throw ModbusException("Wrong response function")
    }
}

/** Must be called exclusively by ModbusScheduler, including multi-step commands. */
class ModbusRtu(private val transport: SerialTransport, private val address: Int) {
    suspend fun read(start: Int, count: Int): List<Int> {
        require(start in 0..65535 && count in 1..125 && start + count <= 65536)
        val response = exchange(RtuCodec.frame(address, 3, start, count), 5 + count * 2)
        RtuCodec.validate(response, address, 3)
        if ((response[2].toInt() and 255) != count * 2) throw ModbusException("Byte count mismatch")
        return List(count) { i -> ((response[3 + i * 2].toInt() and 255) shl 8) or (response[4 + i * 2].toInt() and 255) }
    }
    suspend fun write(register: Int, value: Int) {
        require(register in 0..65535 && value in 0..65535)
        val request = RtuCodec.frame(address, 6, register, value)
        val response = exchange(request, 8)
        RtuCodec.validate(response, address, 6)
        if (!response.contentEquals(request)) throw ModbusException("Write echo mismatch")
    }
    private suspend fun exchange(request: ByteArray, expected: Int): ByteArray {
        try {
            transport.write(request)
            val started = TimeSource.Monotonic.markNow()
            val bytes = mutableListOf<Byte>()
            var length = expected
            while (bytes.size < length) {
                val remaining = 250 - started.elapsedNow().inWholeMilliseconds.toInt()
                if (remaining <= 0) throw ModbusException("Response timeout (250 ms)")
                bytes.addAll(transport.read(length - bytes.size, remaining.coerceAtMost(25)).toList())
                if (bytes.size >= 2 && bytes[1].toInt() and 0x80 != 0) length = 5
            }
            return bytes.toByteArray()
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) {
            // Discard late bytes for a bounded recovery interval before another request.
            val drain = TimeSource.Monotonic.markNow()
            while (drain.elapsedNow().inWholeMilliseconds < 80) {
                transport.read(256, 10)
            }
            throw e
        }
    }
}
