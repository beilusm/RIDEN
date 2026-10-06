package io.github.beilusm.ridenps.core

import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime

data class RegisterDefinition(val address: Int, val name: String, val scale: Int = 1, val unit: String = "", val writable: Boolean = false, val max: Double = 65535.0, val min: Double = 0.0, val source: String = "unknown") {
    val digits get() = when (scale) { 10000 -> 4; 1000 -> 3; 100 -> 2; else -> 0 }
    fun encode(value: Double): Int {
        require(writable && value.isFinite() && value in min..max) { "Invalid value for $name ($min..$max $unit)" }
        val encoded = kotlin.math.round(value * scale)
        require(kotlin.math.abs(encoded - value * scale) < 0.000001) { "Unsupported precision for $name" }
        return encoded.toInt().also { require(it in 0..65535) }
    }
}

object Registers {
    val all: List<RegisterDefinition> = List(121) { address ->
        when (address) {
            0 -> RegisterDefinition(0, "Model", source = "datasheet")
            1, 2 -> RegisterDefinition(address, "Serial number ${if (address == 1) "high" else "low"}", source = "datasheet")
            3 -> RegisterDefinition(3, "Firmware", source = "datasheet")
            4, 6 -> RegisterDefinition(address, "Temperature sign", source = "datasheet")
            5, 7 -> RegisterDefinition(address, "Temperature", unit = if (address == 5) "°C" else "°F", source = "datasheet")
            8 -> RegisterDefinition(8, "Set voltage", 100, "V", source = "codeConfirmed")
            9 -> RegisterDefinition(9, "Set current", 1000, "A", source = "codeConfirmed")
            10 -> RegisterDefinition(10, "Output voltage", 100, "V", source = "codeConfirmed")
            11 -> RegisterDefinition(11, "Output current", 1000, "A", source = "codeConfirmed")
            12, 13 -> RegisterDefinition(address, "Power ${if (address == 12) "high" else "low"}", source = "datasheet")
            14 -> RegisterDefinition(14, "Input voltage", 100, "V", source = "inferred")
            15 -> RegisterDefinition(15, "Key lock", writable = true, max = 1.0, source = "datasheet")
            16 -> RegisterDefinition(16, "Protection", source = "datasheet")
            17 -> RegisterDefinition(17, "CV / CC", source = "datasheet")
            18 -> RegisterDefinition(18, "Output enable", writable = true, max = 1.0, source = "datasheet")
            19 -> RegisterDefinition(19, "Quick preset", writable = true, min = 1.0, max = 9.0, source = "datasheet")
            39 -> RegisterDefinition(39, "Capacity", unit = "mAh", source = "inferred")
            41 -> RegisterDefinition(41, "Energy", unit = "mWh", source = "inferred")
            72 -> RegisterDefinition(72, "Backlight", writable = true, source = "inferred")
            in 80..119 -> {
                val field = (address - 80) % 4
                val current = field == 1 || field == 3
                RegisterDefinition(address, "M${(address - 80) / 4} ${listOf("Voltage", "Current", "OVP", "OCP")[field]}", if (current) 1000 else 100, if (current) "A" else "V", source = "codeConfirmed")
            }
            else -> RegisterDefinition(address, "Unknown")
        }
    }

    fun forDevice(capabilities: DeviceCapabilities?): List<RegisterDefinition> = all.map { definition ->
        val address = definition.address
        val field = when (address) { 8, 10 -> 0; 9, 11 -> 1; in 80..119 -> (address - 80) % 4; else -> null }
        if (capabilities == null && address == 19) definition.copy(writable = false)
        else if (field == null) definition
        else if (capabilities == null) definition.copy(scale = 1, unit = "", writable = false)
        else definition.copy(
            scale = if (field == 1 || field == 3) capabilities.currentScale else capabilities.voltageScale,
            max = when (field) { 0 -> capabilities.maxVoltage; 1 -> capabilities.maxCurrent; 2 -> capabilities.maxOvp; else -> capabilities.maxOcp },
            writable = address != 10 && address != 11
        )
    }
}

data class PowerSnapshot(
    val timestamp: Long = 0, val voltage: Double = 0.0, val current: Double = 0.0,
    val inputVoltage: Double = 0.0, val temperature: Double = 0.0,
    val outputEnabled: Boolean = false, val protection: Int = 0, val activeSlot: Int = 0
) {
    val power get() = voltage * current
    fun csv(): String {
        val time = Instant.fromEpochMilliseconds(timestamp).toLocalDateTime(TimeZone.currentSystemDefault())
        return "$time,$voltage,$current,$power,$inputVoltage,$temperature,$outputEnabled,$protection,$activeSlot"
    }
    companion object { const val CSV_HEADER = "time,voltage,current,power,inputVoltage,temperature,outputEnable,protectionState,activeSlot" }
}

data class DeviceState(val registers: List<Int?> = List(121) { null }, val snapshot: PowerSnapshot = PowerSnapshot()) {
    private fun r(i: Int) = registers[i] ?: 0
    val model get() = r(0)
    val capabilities = DeviceCapabilities.fromModel(model)
    val definitions = Registers.forDevice(capabilities)
    val firmware get() = r(3)
    private fun physical(address: Int) = r(address).toDouble() / definitions[address].scale
    val setVoltage get() = physical(8)
    val setCurrent get() = physical(9)
    val activeSlot get() = r(19).coerceIn(0, 9)
    val ovp get() = physical(80 + activeSlot * 4 + 2)
    val ocp get() = physical(80 + activeSlot * 4 + 3)
    val mode get() = if (r(17) == 1) "CC" else "CV"
    val capacity get() = r(39)
    val energy get() = r(41)
    fun merge(start: Int, values: List<Int>, timestamp: Long, sample: Boolean): DeviceState {
        val merged = registers.toMutableList()
        values.forEachIndexed { i, value -> merged[start + i] = value }
        val state = copy(registers = merged)
        return if (!sample || state.capabilities == null) state else state.copy(snapshot = PowerSnapshot(timestamp, state.physical(10), state.physical(11), state.r(14) / 100.0, state.r(5).toDouble() * if (state.r(4) == 1) -1 else 1, state.r(18) == 1, state.r(16), state.activeSlot))
    }
}
