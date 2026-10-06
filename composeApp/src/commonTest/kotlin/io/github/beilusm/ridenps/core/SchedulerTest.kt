package io.github.beilusm.ridenps.core

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class SchedulerTest {
    @Test fun agingPreventsStarvationAndExpiredPollsAreSkipped() = runTest {
        var now = 0L
        val scheduler = ModbusScheduler(backgroundScope) { now }
        val gate = CompletableDeferred<Unit>()
        val first = async { scheduler.submit(Priority.WRITE) { gate.await() } }
        runCurrent()
        val order = mutableListOf<String>()
        val slow = async { scheduler.submit(Priority.SLOW) { order += "slow" } }
        val expired = async { runCatching { scheduler.submit(Priority.FAST, "fast", 300) { order += "expired" } } }
        runCurrent()
        now = 4000
        val write = async { scheduler.submit(Priority.WRITE) { order += "write" } }
        runCurrent()
        gate.complete(Unit)
        awaitAll(first, slow, write)
        assertIs<CancellationException>(expired.await().exceptionOrNull())
        assertEquals(listOf("slow", "write"), order)
        scheduler.close()
    }
    @Test fun serialExecutionPriorityAndWriteFifo() = runTest {
        val scheduler = ModbusScheduler(backgroundScope)
        val gate = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val first = async { scheduler.submit(Priority.FAST) { gate.await(); order += "running" } }
        runCurrent()
        val slow = async { scheduler.submit(Priority.SLOW) { order += "slow" } }
        val fast = async { scheduler.submit(Priority.FAST) { order += "fast" } }
        val write1 = async { scheduler.submit(Priority.WRITE) { order += "write1" } }
        val write2 = async { scheduler.submit(Priority.WRITE) { order += "write2" } }
        runCurrent()
        gate.complete(Unit)
        awaitAll(first, slow, fast, write1, write2)
        assertEquals(listOf("running", "write1", "write2", "fast", "slow"), order)
        scheduler.close()
    }
    @Test fun dedupCompletesEveryWaiter() = runTest {
        val scheduler = ModbusScheduler(backgroundScope)
        val gate = CompletableDeferred<Unit>()
        val first = async { scheduler.submit(Priority.WRITE) { gate.await() } }
        runCurrent()
        var calls = 0
        val a = async { scheduler.submit(Priority.FAST, "fast") { calls++; 42 } }
        val b = async { scheduler.submit(Priority.FAST, "fast") { calls++; 43 } }
        runCurrent()
        gate.complete(Unit)
        first.await()
        assertEquals(42, a.await()); assertEquals(42, b.await()); assertEquals(1, calls)
        scheduler.close()
    }
    @Test fun closeSettlesRunningAndPendingTasks() = runTest {
        val scheduler = ModbusScheduler(backgroundScope)
        val first = async { runCatching { scheduler.submit(Priority.USER) { awaitCancellation() } } }
        runCurrent()
        val second = async { runCatching { scheduler.submit(Priority.SLOW) { 1 } } }
        runCurrent()
        scheduler.close()
        assertIs<CancellationException>(first.await().exceptionOrNull())
        assertIs<CancellationException>(second.await().exceptionOrNull())
        assertEquals(0, scheduler.stats.value.queued)
    }
    @Test fun failedCommandDoesNotStopQueue() = runTest {
        val scheduler = ModbusScheduler(backgroundScope)
        assertFailsWith<IllegalArgumentException> { scheduler.submit(Priority.USER) { throw IllegalArgumentException("bad") } }
        assertEquals(7, scheduler.submit(Priority.USER) { 7 })
        assertEquals(1, scheduler.stats.value.failed)
        scheduler.close()
    }
}
