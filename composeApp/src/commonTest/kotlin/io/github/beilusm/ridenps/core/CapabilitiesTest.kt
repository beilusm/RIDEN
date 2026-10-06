package io.github.beilusm.ridenps.core

import kotlin.test.*

class CapabilitiesTest {
    @Test fun resolvesBaseAndDerivativeIdsWithoutTreatingPrecisionModelsAsStandard() {
        assertEquals(DeviceCapabilities.fromModel(6006), DeviceCapabilities.fromModel(60067))
        assertEquals(DeviceCapabilities.fromModel(6012), DeviceCapabilities.fromModel(60121))
        assertEquals(DeviceCapabilities.fromModel(6018), DeviceCapabilities.fromModel(60181))
        assertEquals(DeviceCapabilities.fromModel(6024), DeviceCapabilities.fromModel(60241))
        assertEquals(DeviceCapabilities.fromModel(6030), DeviceCapabilities.fromModel(60301))
        assertEquals(10000, DeviceCapabilities.fromModel(60065)?.currentScale)
        assertEquals("RD6006P", DeviceCapabilities.fromModel(60065)?.name)
        assertNull(DeviceCapabilities.fromModel(60125))
        assertNull(DeviceCapabilities.fromModel(9999))
        assertNull(DeviceCapabilities.fromModel(0))
    }

    @Test fun everySetpointAndProtectionRegisterUsesSeparateModelLimits() {
        for (model in listOf(6006, 60067, 60065, 60121, 60181, 60241, 60301, 8009)) {
            val capability = requireNotNull(DeviceCapabilities.fromModel(model))
            val definitions = Registers.forDevice(capability)
            val limits = listOf(capability.maxVoltage, capability.maxCurrent, capability.maxOvp, capability.maxOcp)
            for (slot in 0..9) for (field in 0..3) {
                val d = definitions[80 + slot * 4 + field]
                assertEquals(limits[field], d.max)
                assertEquals(kotlin.math.round(limits[field] * d.scale).toInt(), d.encode(limits[field]))
                assertFailsWith<IllegalArgumentException> { d.encode(limits[field] + 1.0 / d.scale) }
            }
            assertEquals(capability.maxVoltage, definitions[8].max)
            assertEquals(capability.maxCurrent, definitions[9].max)
            assertFailsWith<IllegalArgumentException> { definitions[8].encode(capability.maxOvp) }
            assertFailsWith<IllegalArgumentException> { definitions[9].encode(capability.maxOcp) }
            assertFalse(definitions[10].writable)
            assertFalse(definitions[11].writable)
        }
    }

    @Test fun sixAmpAndNineAmpModelsHaveExpectedHeadroom() {
        val six = requireNotNull(DeviceCapabilities.fromModel(60067))
        assertEquals(listOf(61.0, 6.1, 62.0, 6.2), listOf(six.maxVoltage, six.maxCurrent, six.maxOvp, six.maxOcp))
        val nine = requireNotNull(DeviceCapabilities.fromModel(8009))
        assertEquals(listOf(81.0, 9.1, 82.0, 9.2), listOf(nine.maxVoltage, nine.maxCurrent, nine.maxOvp, nine.maxOcp))
        val definitions = Registers.forDevice(nine)
        assertEquals(8100, definitions[8].encode(81.0))
        assertEquals(9100, definitions[9].encode(9.1))
    }

    @Test fun currentScaleFlowsThroughReadsPresetsAndCsv() {
        for (model in listOf(60067, 60121, 60181, 60241, 60301, 8009, 60065)) {
            val capability = requireNotNull(DeviceCapabilities.fromModel(model))
            val data = MutableList(121) { 0 }.apply {
                this[0] = model
                this[19] = 2
                this[8] = (12 * capability.voltageScale)
                this[9] = (2 * capability.currentScale)
                this[10] = this[8]
                this[11] = this[9]
                this[14] = 4800
                this[90] = (25 * capability.voltageScale)
                this[91] = (3 * capability.currentScale)
            }
            val state = DeviceState().merge(0, data, 100, true)
            assertEquals(12.0, state.setVoltage)
            assertEquals(2.0, state.setCurrent)
            assertEquals(25.0, state.ovp)
            assertEquals(3.0, state.ocp)
            assertEquals(12.0, state.snapshot.voltage)
            assertEquals(2.0, state.snapshot.current)
            assertEquals(48.0, state.snapshot.inputVoltage)
            assertEquals(24.0, state.snapshot.power)
            assertTrue(state.snapshot.csv().contains(",12.0,2.0,24.0,48.0,"))
            assertFailsWith<IllegalArgumentException> { state.definitions[9].encode(0.5 / capability.currentScale) }
        }
    }

    @Test fun unknownModelsKeepRawValuesAndBlockPowerParameters() {
        val state = DeviceState().merge(0, listOf(9999), 100, false)
        for (address in listOf(8, 9, 10, 11) + (80..119)) {
            assertFalse(state.definitions[address].writable)
            assertEquals(1, state.definitions[address].scale)
            assertEquals("", state.definitions[address].unit)
        }
        assertFalse(state.definitions[19].writable)
        assertEquals(0L, state.merge(10, listOf(1200, 1500), 200, true).snapshot.timestamp)
    }
}
