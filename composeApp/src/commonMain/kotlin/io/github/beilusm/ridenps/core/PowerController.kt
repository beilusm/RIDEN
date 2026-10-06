package io.github.beilusm.ridenps.core

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.datetime.Clock

enum class Connection { OFFLINE, CONNECTING, ONLINE, TIMEOUT, ERROR }
data class AppState(
    val connection: Connection = Connection.OFFLINE, val device: DeviceState = DeviceState(),
    val devices: List<SerialDevice> = emptyList(), val port: String? = null,
    val history: List<PowerSnapshot> = emptyList(), val message: String? = null,
    val busy: Boolean = false, val recording: Boolean = false, val recorded: Long = 0,
    val recordingOpen: Boolean = false,
    val recordingPath: String? = null, val autoConnect: Boolean = true,
    val config: SerialConfig = SerialConfig(),
    val scheduler: SchedulerStats = SchedulerStats()
)

class PowerController(private val platform: PlatformServices, private val dispatcher: CoroutineDispatcher = Dispatchers.Main) {
    private val scope = CoroutineScope(SupervisorJob() + dispatcher)
    private val stateFlow = MutableStateFlow(AppState())
    val state = stateFlow.asStateFlow()
    private val lifecycle = Mutex()
    private val recordingLock = Mutex()
    private var session: Session? = null
    private var closing = false
    private var lastConfig = SerialConfig()
    private var preferredPort: String? = null
    private var recorder: Recorder? = null
    private class Session(val transport: SerialTransport, val scheduler: ModbusScheduler, val rtu: ModbusRtu) {
        val jobs = mutableListOf<Job>()
    }
    private class Recorder(val sink: RecordingSink, val queue: Channel<PowerSnapshot>, val job: Job)

    init {
        scope.launch {
            while (isActive) {
                try {
                    val devices = platform.transport.devices()
                    stateFlow.update { it.copy(devices = devices) }
                    val current = session
                    if (current != null && state.value.port != "demo" && devices.none { it.id == state.value.port }) disconnectInternal()
                    if (!closing && session == null && state.value.autoConnect) {
                        val target = devices.firstOrNull { it.id == preferredPort } ?: devices.firstOrNull { it.preferred }
                        if (target != null) connectInternal(target, lastConfig)
                    }
                } catch (e: CancellationException) { throw e }
                catch (e: Exception) { message(e) }
                delay(1000)
            }
        }
    }

    fun connect(device: SerialDevice, config: SerialConfig) = scope.launch { connectInternal(device, config) }
    private suspend fun connectInternal(device: SerialDevice, config: SerialConfig) = lifecycle.withLock {
        if (closing || session != null) return@withLock
        lastConfig = config; preferredPort = device.id
        stateFlow.update { it.copy(connection = Connection.CONNECTING, message = null, port = device.id, config = config) }
        val transport = if (device.id == "demo") DemoTransport() else platform.transport
        val scheduler = ModbusScheduler(scope)
        val current = Session(transport, scheduler, ModbusRtu(transport, config.address))
        try {
            transport.open(device, config)
            val registers = scheduler.submit(Priority.USER) { current.rtu.read(0, 121) }
            session = current
            stateFlow.update { it.copy(connection = Connection.ONLINE, history = emptyList(), device = DeviceState().merge(0, registers, now(), false)) }
            current.jobs += scope.launch { scheduler.stats.collect { stats -> if (session === current) stateFlow.update { it.copy(scheduler = stats) } } }
            current.jobs += scope.launch {
                var failures = 0
                while (isActive) {
                    val started = kotlin.time.TimeSource.Monotonic.markNow()
                    try {
                        val values = scheduler.submit(Priority.FAST, "fast", 300) { current.rtu.read(4, 80) }
                        if (session === current) {
                            failures = 0
                            val deviceState = state.value.device.merge(4, values, now(), true)
                            stateFlow.update { it.copy(connection = Connection.ONLINE, device = deviceState, history = if (deviceState.capabilities != null) (it.history + deviceState.snapshot).takeLast(300) else it.history) }
                            if (deviceState.capabilities != null) recordSample(deviceState.snapshot)
                        }
                    } catch (e: CancellationException) { currentCoroutineContext().ensureActive() }
                    catch (e: Exception) {
                        failures++
                        if (session === current) stateFlow.update { it.copy(connection = if (failures >= 3) Connection.ERROR else Connection.TIMEOUT, message = e.message) }
                    }
                    delay((150 - started.elapsedNow().inWholeMilliseconds).coerceAtLeast(1))
                }
            }
            current.jobs += scope.launch {
                var slot = 0
                while (isActive) {
                    delay(1000)
                    try {
                        val active = scheduler.submit(Priority.SLOW, "active") { current.rtu.read(19, 1) }
                        merge(current, 19, active)
                        repeat(2) {
                            val index = slot
                            val values = scheduler.submit(Priority.SLOW, "slot_M$index") { current.rtu.read(80 + index * 4, 4) }
                            merge(current, 80 + index * 4, values)
                            slot = (slot + 1) % 10
                        }
                    } catch (e: CancellationException) { currentCoroutineContext().ensureActive() }
                    catch (e: Exception) { message(e) }
                }
            }
        } catch (e: Exception) {
            withContext(NonCancellable) {
                runCatching { scheduler.close() }
                runCatching { transport.close() }
            }
            if (e is CancellationException) throw e
            stateFlow.update { it.copy(connection = Connection.ERROR, message = e.message, port = null, autoConnect = false) }
        }
    }

    fun disconnect() = scope.launch {
        stateFlow.update { it.copy(autoConnect = false) }
        disconnectInternal()
    }
    private suspend fun disconnectInternal() = lifecycle.withLock {
        val current = session
        session = null
        withContext(NonCancellable) {
            try {
                if (current != null) {
                    current.jobs.forEach { it.cancel() }
                    current.jobs.joinAll()
                    current.scheduler.close()
                }
            } finally {
                try { current?.transport?.close() } catch (e: Exception) { message(e) }
                stateFlow.update { it.copy(connection = Connection.OFFLINE, port = null, busy = false, scheduler = SchedulerStats()) }
            }
        }
    }
    fun setAutoConnect(enabled: Boolean) { stateFlow.update { it.copy(autoConnect = enabled) } }
    fun dismissMessage() { stateFlow.update { it.copy(message = null) } }
    fun clearHistory() { stateFlow.update { it.copy(history = emptyList()) } }

    private fun command(block: suspend (Session) -> Unit) = scope.launch {
        if (state.value.busy) return@launch
        val current = session ?: return@launch
        stateFlow.update { it.copy(busy = true, message = null) }
        try { block(current) }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { message(e) }
        finally { stateFlow.update { it.copy(busy = false) } }
    }
    fun write(address: Int, physical: Double) = command { current ->
        val device = state.value.device
        require(device.capabilities != null || (address != 19 && !(address == 18 && physical != 0.0))) { "型号 ${device.model} 尚未支持，禁止载入预设或开启输出" }
        val definition = device.definitions.getOrNull(address) ?: error("Unknown register")
        val value = definition.encode(physical)
        current.scheduler.submit(Priority.WRITE) {
            if (address == 19) {
                val base = 80 + value * 4
                val preset = current.rtu.read(base, 4)
                preset.forEachIndexed { i, raw ->
                    val field = device.definitions[base + i]
                    field.encode(raw.toDouble() / field.scale)
                }
            }
            current.rtu.write(address, value)
            if (address == 19) delay(600)
            val registers = current.rtu.read(0, 121)
            merge(current, 0, registers)
        }
    }
    fun setOutput(enabled: Boolean) = write(18, if (enabled) 1.0 else 0.0)
    fun quickSwitch(slot: Int) = write(19, slot.toDouble())
    fun refreshRegisters(automatic: Boolean = false): Job {
        suspend fun read(current: Session) {
            val values = current.scheduler.submit(if (automatic) Priority.SLOW else Priority.USER, if (automatic) "registers" else null) { current.rtu.read(0, 121) }
            merge(current, 0, values)
        }
        return if (!automatic) command { read(it) } else scope.launch {
            val current = session ?: return@launch
            try { read(current) }
            catch (e: CancellationException) { throw e }
            catch (e: Exception) { message(e) }
        }
    }
    fun saveSlot(slot: Int, values: List<Double>) = command { current ->
        require(slot in 1..9 && values.size == 4)
        val base = 80 + slot * 4
        val definitions = state.value.device.definitions
        val raw = values.mapIndexed { i, v -> definitions[base + i].encode(v) }
        current.scheduler.submit(Priority.WRITE) {
            raw.forEachIndexed { i, value -> current.rtu.write(base + i, value) }
            val actual = current.rtu.read(base, 4)
            merge(current, base, actual)
            check(actual == raw) { "Preset readback mismatch" }
        }
    }

    fun toggleRecording() = scope.launch {
        recordingLock.withLock {
            try {
                if (recorder != null) stopRecording() else {
                    require(state.value.device.capabilities != null) { "型号尚未支持，无法录制物理量" }
                    val sink = platform.startRecording() ?: return@withLock
                    try { sink.append(PowerSnapshot.CSV_HEADER) }
                    catch (e: Exception) { runCatching { sink.finish(export = false) }; throw e }
                    val queue = Channel<PowerSnapshot>(1024)
                    val job = scope.launch {
                        try {
                            for (snapshot in queue) {
                                sink.append(snapshot.csv())
                                stateFlow.update { it.copy(recorded = it.recorded + 1) }
                            }
                        } catch (e: Exception) {
                            queue.cancel()
                            stateFlow.update { it.copy(recording = false, message = "Recording: ${e.message}") }
                        }
                    }
                    recorder = Recorder(sink, queue, job)
                    stateFlow.update { it.copy(recording = true, recordingOpen = true, recorded = 0, recordingPath = null) }
                }
            } catch (e: CancellationException) { throw e }
            catch (e: Exception) { message(e) }
        }
    }
    private suspend fun stopRecording(export: Boolean = true) {
        val recording = recorder ?: return
        recorder = null
        recording.queue.close()
        recording.job.join()
        stateFlow.update { it.copy(recording = false, recordingOpen = false) }
        val path = recording.sink.finish(export)
        stateFlow.update { it.copy(recordingPath = path) }
    }
    private suspend fun recordSample(snapshot: PowerSnapshot) {
        if (recorder == null) return
        try {
            recordingLock.withLock { recorder?.queue?.send(snapshot) }
        } catch (e: CancellationException) { currentCoroutineContext().ensureActive() }
        catch (e: Exception) { stateFlow.update { it.copy(recording = false, message = "Recording: ${e.message}") } }
    }
    fun exportRegisters() = scope.launch {
        try {
            val device = state.value.device
            val text = "address,name,raw,value,unit,source\n" + device.definitions.joinToString("\n") { d ->
                val raw = device.registers[d.address]
                "${d.address},${d.name},${raw ?: ""},${raw?.let { it.toDouble() / d.scale } ?: ""},${d.unit},${d.source}"
            }
            platform.exportText("riden-registers.csv", text)?.let { path -> stateFlow.update { it.copy(message = path) } }
        } catch (e: Exception) { message(e) }
    }
    suspend fun close(exportRecordings: Boolean = true) = withContext(dispatcher) {
        closing = true
        stateFlow.update { it.copy(autoConnect = false) }
        try {
            disconnectInternal()
            recordingLock.withLock { stopRecording(exportRecordings) }
        } finally { scope.cancel() }
    }
    private fun merge(current: Session, start: Int, values: List<Int>) {
        if (session === current) stateFlow.update { it.copy(device = it.device.merge(start, values, now(), false)) }
    }
    private fun message(e: Exception) { stateFlow.update { it.copy(message = e.message ?: e.toString()) } }
    private fun now() = Clock.System.now().toEpochMilliseconds()
}
