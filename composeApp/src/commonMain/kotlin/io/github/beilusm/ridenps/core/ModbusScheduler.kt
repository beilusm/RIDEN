package io.github.beilusm.ridenps.core

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.time.TimeSource

enum class Priority(val rank: Int) { WRITE(0), USER(2), FAST(4), SLOW(6) }
data class SchedulerStats(val queued: Int = 0, val completed: Long = 0, val failed: Long = 0)

/** One owner of the wire. Pending polls coalesce; writes always keep FIFO order. */
class ModbusScheduler(private val scope: CoroutineScope, private val nowMs: () -> Long = monotonicClock()) {
    private class Task(
        val priority: Priority, val key: String?, val expiresMs: Long?,
        val created: Long,
        val result: CompletableDeferred<Any?>, val run: suspend () -> Any?
    )
    private val lock = Mutex()
    private val pending = mutableListOf<Task>()
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private var closed = false
    private val mutableStats = kotlinx.coroutines.flow.MutableStateFlow(SchedulerStats())
    val stats = mutableStats.asStateFlow()
    private val worker = scope.launch {
        var active: Task? = null
        try {
            for (ignored in wake) {
                while (true) {
                    val task = lock.withLock {
                        val expired = pending.filter { it.expiresMs != null && nowMs() - it.created > it.expiresMs }
                        expired.forEach { it.result.completeExceptionally(CancellationException("Poll expired")) }
                        pending.removeAll(expired.toSet())
                        pending.minByOrNull {
                            it.priority.rank - ((nowMs() - it.created) / 500).toInt()
                        }?.also { pending.remove(it) }
                    } ?: break
                    active = task
                    mutableStats.value = mutableStats.value.copy(queued = lock.withLock { pending.size })
                    try {
                        task.result.complete(task.run())
                        mutableStats.value = mutableStats.value.copy(completed = mutableStats.value.completed + 1)
                    } catch (e: CancellationException) {
                        task.result.completeExceptionally(e)
                        currentCoroutineContext().ensureActive()
                    } catch (e: Exception) {
                        task.result.completeExceptionally(e)
                        mutableStats.value = mutableStats.value.copy(failed = mutableStats.value.failed + 1)
                    }
                    active = null
                }
            }
        } finally {
            withContext(NonCancellable) {
                lock.withLock {
                    closed = true
                    val error = CancellationException("Scheduler closed")
                    active?.result?.completeExceptionally(error)
                    pending.forEach { it.result.completeExceptionally(error) }
                    pending.clear()
                    mutableStats.value = mutableStats.value.copy(queued = 0)
                    wake.close()
                }
            }
        }
    }

    suspend fun <T> submit(priority: Priority, key: String? = null, expiresMs: Long? = null, run: suspend () -> T): T {
        val result = lock.withLock {
            check(!closed && worker.isActive) { "Scheduler closed" }
            val existing = key?.let { k -> pending.firstOrNull { it.key == k } }
            if (existing != null) existing.result else {
                check(pending.size < 128) { "Scheduler queue full" }
                val deferred = CompletableDeferred<Any?>()
                pending.add(Task(priority, key, expiresMs, nowMs(), deferred, run))
                mutableStats.value = mutableStats.value.copy(queued = pending.size)
                wake.trySend(Unit)
                deferred
            }
        }
        @Suppress("UNCHECKED_CAST")
        return result.await() as T
    }

    suspend fun close() {
        lock.withLock { closed = true }
        worker.cancelAndJoin()
    }
}

private fun monotonicClock(): () -> Long {
    val origin = TimeSource.Monotonic.markNow()
    return { origin.elapsedNow().inWholeMilliseconds }
}
