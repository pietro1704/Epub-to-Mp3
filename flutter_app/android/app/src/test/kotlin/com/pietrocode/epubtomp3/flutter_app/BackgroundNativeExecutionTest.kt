package com.pietrocode.epubtomp3.flutter_app

import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class BackgroundNativeExecutionTest {
    @Test fun coroutineCancellationSignalsRustWhileItsNativeCallStillBlocks() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val execution = BackgroundNativeExecution({}, {
            cancelled.set(true)
            release.countDown()
            true
        })
        val work = launch {
            watchBackgroundNativeCancellation(execution) {
                withContext(Dispatchers.IO) {
                    execution.run("output", { coroutineContext.ensureActive() }) {
                        entered.complete(Unit)
                        assertTrue(release.await(1, TimeUnit.SECONDS), "Cancellation must reach native work before it returns")
                        "native result"
                    }
                }
            }
        }
        try {
            entered.await()
            work.cancelAndJoin()
            assertTrue(cancelled.get())
        } finally { release.countDown(); work.cancelAndJoin() }
    }

    @Test fun stopBeforeLoadingNativeCodeDoesNotCallAnUnpreparedNativeControl() {
        val prepared = AtomicBoolean(false)
        var cancellations = 0
        val execution = BackgroundNativeExecution({ prepared.set(true) }, {
            assertTrue(prepared.get())
            cancellations++
            true
        })
        execution.stop()
        assertEquals(0, cancellations)
        assertFailsWith<CancellationException> { execution.run("output", {}) { error("must not start") } }
        assertEquals(1, cancellations)
    }

    @Test fun stoppingBetweenPrepareAndPublishingActiveOutputCannotBeLost() {
        val prepared = AtomicBoolean(false)
        val cancelled = AtomicBoolean(false)
        var nativeCalls = 0
        lateinit var execution: BackgroundNativeExecution
        execution = BackgroundNativeExecution({
            prepared.set(true)
            execution.stop()
        }, {
            assertTrue(prepared.get())
            cancelled.set(true)
            true
        })
        assertFailsWith<CancellationException> {
            execution.run("output", {}) { nativeCalls++; "unexpected" }
        }
        assertTrue(cancelled.get())
        assertEquals(0, nativeCalls)
    }

    @Test fun coroutineCancellationAfterPrepareCancelsThePreparedRustControl() {
        var prepared = false
        var cancelled = false
        val execution = BackgroundNativeExecution({ prepared = true }, {
            assertTrue(prepared)
            cancelled = true
            true
        })
        assertFailsWith<CancellationException> {
            execution.run("output", { throw CancellationException("coroutine stopped") }) { error("must not start") }
        }
        assertTrue(cancelled)
    }

    @Test fun stoppingWhileNativeWorkRunsSignalsItsControlAndCannotReportSuccess() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val prepared = AtomicBoolean(false)
        val pool = Executors.newSingleThreadExecutor()
        val execution = BackgroundNativeExecution({ prepared.set(true) }, {
            assertTrue(prepared.get())
            cancelled.set(true)
            release.countDown()
            true
        })
        try {
            val result = pool.submit<String> {
                try {
                    execution.run("output", {}) { entered.countDown(); release.await(); "native completed" }
                } catch (_: CancellationException) { "cancelled" }
            }
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            execution.stop()
            assertEquals("cancelled", result.get(1, TimeUnit.SECONDS))
            assertTrue(cancelled.get())
        } finally { release.countDown(); pool.shutdownNow() }
    }

    @Test fun aCompletedRequestNoLongerOwnsACancellationTarget() {
        val cancellations = AtomicInteger(0)
        val execution = BackgroundNativeExecution({}, { cancellations.incrementAndGet(); true })
        assertEquals("complete", execution.run("output", {}) { "complete" })
        execution.stop()
        assertEquals(0, cancellations.get())
    }
}
