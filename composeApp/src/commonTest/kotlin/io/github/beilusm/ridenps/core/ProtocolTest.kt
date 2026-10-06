package io.github.beilusm.ridenps.core

import kotlinx.coroutines.test.runTest
import kotlin.test.*

class ProtocolTest {
    private class Fragments(private val reply: (ByteArray) -> ByteArray) : SerialTransport {
        private var response = byteArrayOf()
        override suspend fun devices() = emptyList<SerialDevice>()
        override suspend fun open(device: SerialDevice, config: SerialConfig) = Unit
        override suspend fun close() = Unit
        override suspend fun write(bytes: ByteArray) { response = reply(bytes) }
        override suspend fun read(maxBytes: Int, timeoutMs: Int): ByteArray {
            kotlinx.coroutines.delay(1)
            val bytes = response.take(minOf(2, maxBytes)).toByteArray()
            response = response.drop(bytes.size).toByteArray()
            return bytes
        }
    }
    private fun response(vararg bytes: Int): ByteArray {
        val data = bytes.map { it.toByte() }.toByteArray()
        val crc = RtuCodec.crc(data)
        return data + byteArrayOf(crc.toByte(), (crc ushr 8).toByte())
    }
    @Test fun fragmentedResponsesAndExceptionFrames() = runTest {
        val read = ModbusRtu(Fragments { response(1, 3, 4, 0x12, 0x34, 0xab, 0xcd) }, 1)
        assertEquals(listOf(0x1234, 0xabcd), read.read(8, 2))
        val exception = ModbusRtu(Fragments { response(1, 0x83, 2) }, 1)
        val error = assertFailsWith<ModbusException> { exception.read(0, 1) }
        assertEquals("Device exception 2", error.message)
    }
    @Test fun writeEchoMustMatchRegisterAndValue() = runTest {
        val client = ModbusRtu(Fragments { RtuCodec.frame(1, 6, 9, 1200) }, 1)
        assertFailsWith<ModbusException> { client.write(8, 1200) }
    }
    @Test fun crcKnownVector() {
        assertContentEquals(byteArrayOf(1, 3, 0, 0, 0, 10, 0xc5.toByte(), 0xcd.toByte()), RtuCodec.frame(1, 3, 0, 10))
    }
    @Test fun rejectsCorruptAndWrongSlave() {
        val echo = RtuCodec.frame(1, 6, 8, 1200)
        RtuCodec.validate(echo, 1, 6)
        assertFailsWith<ModbusException> { RtuCodec.validate(echo, 2, 6) }
        echo[3] = 3
        assertFailsWith<ModbusException> { RtuCodec.validate(echo, 1, 6) }
    }
    @Test fun schemaGuardsWritesAndM0() {
        val definitions = Registers.forDevice(DeviceCapabilities.fromModel(6006))
        assertEquals(121, Registers.all.size)
        assertFailsWith<IllegalArgumentException> { Registers.all[10].encode(5.0) }
        assertFailsWith<IllegalArgumentException> { Registers.all[20].encode(5.0) }
        assertFailsWith<IllegalArgumentException> { Registers.all[19].encode(0.0) }
        assertFailsWith<IllegalArgumentException> { Registers.all[8].encode(Double.NaN) }
        assertFailsWith<IllegalArgumentException> { definitions[9].encode(7.0) }
        assertEquals(1500, definitions[9].encode(1.5))
    }
    @Test fun slowMergeKeepsMeasurementAndActiveProtection() {
        val registers = MutableList(121) { 0 }.apply { this[0] = 6006; this[19] = 2; this[10] = 1200; this[11] = 1500; this[90] = 2400; this[91] = 2000; this[82] = 6200; this[83] = 6200 }
        val fast = DeviceState().merge(0, registers, 100, true)
        val slow = fast.merge(80, listOf(500, 1000, 6200, 6200), 200, false)
        assertEquals(fast.snapshot, slow.snapshot)
        assertEquals(24.0, slow.ovp)
        assertEquals(2.0, slow.ocp)
        assertEquals(18.0, slow.snapshot.power)
    }
    @Test fun demoRoundTripAndQuickSwitch() = runTest {
        val transport = DemoTransport()
        transport.open(SerialDevice("demo", "Demo"), SerialConfig())
        val client = ModbusRtu(transport, 1)
        client.write(19, 3)
        assertEquals(listOf(1250, 1000), client.read(8, 2))
        client.write(18, 1)
        assertEquals(1, client.read(18, 1).single())
        transport.close()
    }
}
