package io.github.beilusm.ridenps.core

import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ControllerTest {
    private class ModelTransport(model: Int) : SerialTransport {
        private val delegate = DemoTransport(model)
        val writes = mutableListOf<Pair<Int, Int>>()
        override suspend fun devices() = listOf(SerialDevice("test", "Test"))
        override suspend fun open(device: SerialDevice, config: SerialConfig) = delegate.open(device, config)
        override suspend fun close() = delegate.close()
        override suspend fun read(maxBytes: Int, timeoutMs: Int) = delegate.read(maxBytes, timeoutMs)
        override suspend fun write(bytes: ByteArray) {
            if (bytes[1].toInt() == 6) {
                val address = (bytes[2].toInt() and 255) * 256 + (bytes[3].toInt() and 255)
                val raw = (bytes[4].toInt() and 255) * 256 + (bytes[5].toInt() and 255)
                writes += address to raw
            }
            delegate.write(bytes)
        }
    }
    private fun modelServices(transport: SerialTransport) = object : PlatformServices {
        override val transport = transport
        var exported: String? = null
        override suspend fun startRecording(): RecordingSink? = null
        override suspend fun exportText(name: String, text: String): String { exported = text; return name }
    }

    @Test fun presetRecallValidatesDeviceValuesBeforeSendingSwitchCommand() = runTest {
        val transport = ModelTransport(60067)
        transport.open(SerialDevice("test", "Test"), SerialConfig())
        ModbusRtu(transport, 1).write(84, 6200)
        transport.close()
        transport.writes.clear()
        val controller = PowerController(modelServices(transport), StandardTestDispatcher(testScheduler))
        try {
            controller.setAutoConnect(false)
            controller.connect(SerialDevice("test", "Test"), SerialConfig()).join()
            controller.quickSwitch(1).join()
            assertTrue(transport.writes.isEmpty())
            assertEquals(0, controller.state.value.device.activeSlot)
            assertNotNull(controller.state.value.message)
            controller.saveSlot(1, listOf(61.0, 6.1, 62.0, 6.2)).join()
            controller.quickSwitch(1).join()
            assertEquals(1, controller.state.value.device.activeSlot)
            assertEquals(61.0, controller.state.value.device.setVoltage)
        } finally { controller.close() }
    }

    @Test fun modelLimitsApplyToDirectWritesPresetWritesAndExports() = runTest {
        for (model in listOf(60067, 60121, 8009, 60065)) {
            val transport = ModelTransport(model)
            val services = modelServices(transport)
            val controller = PowerController(services, StandardTestDispatcher(testScheduler))
            try {
                controller.setAutoConnect(false)
                controller.connect(SerialDevice("test", "Test"), SerialConfig()).join()
                val capability = requireNotNull(controller.state.value.device.capabilities)
                controller.write(8, capability.maxOvp).join()
                controller.write(9, capability.maxOcp).join()
                controller.saveSlot(2, listOf(12.0, 1.0, capability.maxOvp + 1, 2.0)).join()
                assertTrue(transport.writes.isEmpty(), "Invalid commands reached the transport for $model")
                controller.write(9, capability.maxCurrent).join()
                assertEquals(capability.maxCurrent, controller.state.value.device.setCurrent)
                controller.saveSlot(2, listOf(capability.maxVoltage, capability.maxCurrent, capability.maxOvp, capability.maxOcp)).join()
                assertEquals(5, transport.writes.size)
                controller.quickSwitch(2).join()
                assertEquals(capability.maxVoltage, controller.state.value.device.setVoltage)
                assertEquals(capability.maxCurrent, controller.state.value.device.setCurrent)
                assertEquals(capability.maxOvp, controller.state.value.device.ovp)
                assertEquals(capability.maxOcp, controller.state.value.device.ocp)
                controller.exportRegisters().join()
                assertTrue(requireNotNull(services.exported).contains("9,Set current,${transport.writes.first().second},${capability.maxCurrent},A,"))
            } finally { controller.close() }
        }
    }

    @Test fun reconnectUpdatesCapabilitiesAndUnknownModelsCannotEnableOutput() = runTest {
        val transport = ModelTransport(9999)
        val controller = PowerController(modelServices(transport), StandardTestDispatcher(testScheduler))
        try {
            controller.setAutoConnect(false)
            controller.connect(SerialDevice("demo", "Demo"), SerialConfig()).join()
            assertEquals("RD6006", controller.state.value.device.capabilities?.name)
            controller.disconnect().join()
            controller.connect(SerialDevice("test", "Unknown"), SerialConfig()).join()
            assertNull(controller.state.value.device.capabilities)
            advanceTimeBy(500)
            assertTrue(controller.state.value.history.isEmpty())
            controller.write(8, 12.0).join()
            controller.quickSwitch(1).join()
            controller.setOutput(true).join()
            controller.saveSlot(1, listOf(12.0, 1.0, 15.0, 2.0)).join()
            assertTrue(transport.writes.isEmpty())
            controller.setOutput(false).join()
            assertEquals(listOf(18 to 0), transport.writes)
        } finally { controller.close() }
    }

    @Test fun pendingFileSelectionDoesNotPausePollingOrCommands() = runTest {
        val selection = kotlinx.coroutines.CompletableDeferred<RecordingSink?>()
        val services = object : PlatformServices {
            override val transport = DemoTransport()
            override suspend fun startRecording() = selection.await()
            override suspend fun exportText(name: String, text: String): String? = null
        }
        val controller = PowerController(services, StandardTestDispatcher(testScheduler))
        try {
            controller.setAutoConnect(false)
            controller.connect(SerialDevice("demo", "Demo"), SerialConfig())
            advanceTimeBy(100)
            val before = controller.state.value.history.size
            val recording = controller.toggleRecording()
            advanceTimeBy(800)
            assertTrue(controller.state.value.history.size >= before + 5)
            controller.setOutput(true).join()
            assertEquals(1, controller.state.value.device.registers[18])
            selection.complete(null)
            recording.join()
            assertFalse(controller.state.value.recordingOpen)
        } finally {
            selection.complete(null)
            controller.close()
        }
    }
    private class FaultTransport : SerialTransport {
        private val delegate = DemoTransport()
        var fail = false
        var failClose = false
        override suspend fun devices() = listOf(SerialDevice("test", "Test"))
        override suspend fun open(device: SerialDevice, config: SerialConfig) = delegate.open(device, config)
        override suspend fun read(maxBytes: Int, timeoutMs: Int): ByteArray {
            if (fail) throw ModbusException("Removed")
            return delegate.read(maxBytes, timeoutMs)
        }
        override suspend fun write(bytes: ByteArray) {
            if (fail) throw ModbusException("Removed")
            delegate.write(bytes)
        }
        override suspend fun close() { delegate.close(); if (failClose) error("Already removed") }
    }
    @Test fun pollFailuresRecoverAndCloseFailureStillClearsSession() = runTest {
        val transport = FaultTransport()
        val services = object : PlatformServices {
            override val transport = transport
            override suspend fun startRecording(): RecordingSink? = null
            override suspend fun exportText(name: String, text: String): String? = null
        }
        val controller = PowerController(services, StandardTestDispatcher(testScheduler))
        try {
            controller.setAutoConnect(false)
            controller.connect(SerialDevice("test", "Test"), SerialConfig())
            advanceTimeBy(100)
            transport.fail = true
            advanceTimeBy(750)
            assertEquals(Connection.ERROR, controller.state.value.connection)
            transport.fail = false
            advanceTimeBy(300)
            assertEquals(Connection.ONLINE, controller.state.value.connection)
            transport.failClose = true
            controller.disconnect().join()
            assertEquals(Connection.OFFLINE, controller.state.value.connection)
            assertNull(controller.state.value.port)
        } finally { controller.close() }
    }
    private class Services(private val failRecording: Boolean = false) : PlatformServices {
        override val transport = DemoTransport()
        val rows = mutableListOf<String>()
        var closed = false
        override suspend fun startRecording() = object : RecordingSink {
            override suspend fun append(line: String) { if (failRecording && rows.size >= 3) error("Disk full"); rows += line }
            override suspend fun finish(export: Boolean): String { closed = true; return "test.csv" }
        }
        override suspend fun exportText(name: String, text: String) = name
    }
    @Test fun recordingFailureDoesNotBecomeSerialFailureAndCanBeClosedOffline() = runTest {
        val services = Services(failRecording = true)
        val controller = PowerController(services, StandardTestDispatcher(testScheduler))
        try {
            controller.setAutoConnect(false)
            controller.connect(SerialDevice("demo", "Demo"), SerialConfig())
            advanceTimeBy(100)
            controller.toggleRecording().join()
            advanceTimeBy(800)
            assertEquals(Connection.ONLINE, controller.state.value.connection)
            assertFalse(controller.state.value.recording)
            assertTrue(controller.state.value.recordingOpen)
            controller.disconnect().join()
            controller.toggleRecording().join()
            assertTrue(services.closed)
            assertFalse(controller.state.value.recordingOpen)
        } finally { controller.close() }
    }
    @Test fun recordingExactlyMatchesFastSamplesAndFlushesOnClose() = runTest {
        val services = Services()
        val controller = PowerController(services, StandardTestDispatcher(testScheduler))
        controller.setAutoConnect(false)
        controller.connect(SerialDevice("demo", "Demo"), SerialConfig())
        advanceTimeBy(100)
        assertEquals(Connection.ONLINE, controller.state.value.connection)
        controller.setOutput(true).join()
        controller.toggleRecording().join()
        val before = controller.state.value.history.size
        advanceTimeBy(700)
        runCurrent()
        val samples = controller.state.value.history.drop(before)
        controller.toggleRecording().join()
        assertEquals(PowerSnapshot.CSV_HEADER, services.rows.first())
        assertEquals(samples.map { it.csv() }, services.rows.drop(1))
        assertTrue(services.closed)
        assertEquals(samples.size.toLong(), controller.state.value.recorded)
        controller.close()
        assertEquals(Connection.OFFLINE, controller.state.value.connection)
    }
    @Test fun quickSwitchAndProtectionTargetActiveSlot() = runTest {
        val controller = PowerController(Services(), StandardTestDispatcher(testScheduler))
        controller.setAutoConnect(false)
        controller.connect(SerialDevice("demo", "Demo"), SerialConfig())
        advanceTimeBy(100)
        controller.quickSwitch(2).join()
        assertEquals(2, controller.state.value.device.activeSlot)
        controller.write(90, 25.0).join()
        assertEquals(25.0, controller.state.value.device.ovp)
        assertEquals(6200, controller.state.value.device.registers[82])
        controller.close()
    }
    @Test fun historyIsBoundedAndReconnectHasFreshSession() = runTest {
        val controller = PowerController(Services(), StandardTestDispatcher(testScheduler))
        controller.setAutoConnect(false)
        controller.connect(SerialDevice("demo", "Demo"), SerialConfig())
        advanceTimeBy(50000)
        assertEquals(300, controller.state.value.history.size)
        controller.disconnect().join()
        assertFalse(controller.state.value.autoConnect)
        val count = controller.state.value.history.size
        advanceTimeBy(1000)
        assertEquals(count, controller.state.value.history.size)
        controller.connect(SerialDevice("demo", "Demo"), SerialConfig())
        advanceTimeBy(100)
        assertEquals(Connection.ONLINE, controller.state.value.connection)
        assertTrue(controller.state.value.history.size < 10)
        controller.close()
    }
}
