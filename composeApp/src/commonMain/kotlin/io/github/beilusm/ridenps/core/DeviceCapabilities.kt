package io.github.beilusm.ridenps.core

data class DeviceCapabilities(
    val name: String,
    val ratedVoltage: Double,
    val ratedCurrent: Double,
    val maxVoltage: Double,
    val maxCurrent: Double,
    val maxOvp: Double,
    val maxOcp: Double,
    val voltageScale: Int = 100,
    val currentScale: Int = 1000
) {
    companion object {
        private val rd6006 = DeviceCapabilities("RD6006", 60.0, 6.0, 61.0, 6.1, 62.0, 6.2)
        private val rd6012 = DeviceCapabilities("RD6012", 60.0, 12.0, 61.0, 12.1, 62.0, 12.2, currentScale = 100)
        private val rd6018 = DeviceCapabilities("RD6018", 60.0, 18.0, 61.0, 18.1, 62.0, 18.2, currentScale = 100)
        private val rd6024 = DeviceCapabilities("RD6024", 60.0, 24.0, 61.0, 24.1, 62.0, 24.2, currentScale = 100)
        private val rd6030 = DeviceCapabilities("RD6030", 60.0, 30.0, 61.0, 30.1, 62.0, 30.2, currentScale = 100)
        private val rk8009 = DeviceCapabilities("RK8009", 80.0, 9.0, 81.0, 9.1, 82.0, 9.2)

        // Check precision variants before their five-digit family IDs.
        fun fromModel(rawModel: Int): DeviceCapabilities? = when (rawModel) {
            60065 -> rd6006.copy(name = "RD6006P", voltageScale = 1000, currentScale = 10000)
            60066 -> rd6006.copy(name = "RK6006")
            6006, in 60060..60064, 60067 -> rd6006
            6012, in 60120..60124 -> rd6012
            6018, in 60180..60189 -> rd6018
            6024, in 60241..60249 -> rd6024
            6030, in 60300..60309 -> rd6030
            8009 -> rk8009
            else -> null
        }
    }
}
