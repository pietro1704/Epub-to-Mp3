package com.pietrocode.epubtomp3.flutter_app

import java.util.concurrent.Future
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame
import kotlin.test.assertTrue

class NativeConversionAwaitTest {
    private open class CompletingFuture(private val completionSeconds: Long) : Future<String> {
        override fun get(timeout: Long, unit: TimeUnit): String {
            assertEquals(TimeUnit.SECONDS, unit, "The JNI watchdog must use explicit seconds")
            if (timeout < completionSeconds) throw TimeoutException("Native work is still progressing")
            return "native result"
        }

        override fun get(): String = error("An unbounded native wait is forbidden")
        override fun cancel(mayInterruptIfRunning: Boolean): Boolean = error("Healthy work must not be cancelled")
        override fun isCancelled(): Boolean = false
        override fun isDone(): Boolean = false
    }

    @Test fun healthyLegacyDeviceConversionCanFinishBeyondTheFormerFifteenMinuteLimit() {
        assertEquals("native result", NativeConversionAwait.await(CompletingFuture(1100), "healthy-output") {
            error("Healthy native work must not be cancelled")
        })
    }

    @Test fun timeoutCancelsExactNativeOutputBeforeInterruptingTheSameFutureAndRethrows() {
        val timeoutFailure = TimeoutException("native work exceeded the finite budget")
        val events = mutableListOf<String>()
        var cancelledFuture: Future<String>? = null
        val future = object : CompletingFuture(0) {
            override fun get(timeout: Long, unit: TimeUnit): String {
                assertTrue(timeout > 0, "The native wait must stay finite and positive")
                assertEquals(TimeUnit.SECONDS, unit)
                events += "await"
                throw timeoutFailure
            }

            override fun cancel(mayInterruptIfRunning: Boolean): Boolean {
                assertTrue(mayInterruptIfRunning)
                cancelledFuture = this
                events += "future cancel"
                return true
            }
        }
        val error = assertFailsWith<TimeoutException> {
            NativeConversionAwait.await(future, "owned-output") { output -> events += "native cancel:$output" }
        }
        assertSame(timeoutFailure, error)
        assertSame(future, cancelledFuture)
        assertEquals(listOf("await", "native cancel:owned-output", "future cancel"), events)
    }

    @Test fun nativeFailurePropagatesWithoutTimeoutWrappingOrCancellation() {
        val failure = ExecutionException(IllegalStateException("native failure"))
        val future = object : CompletingFuture(0) {
            override fun get(timeout: Long, unit: TimeUnit): String = throw failure
        }
        val error = assertFailsWith<ExecutionException> {
            NativeConversionAwait.await(future, "failed-output") { error("Native failure is not a timeout") }
        }
        assertSame(failure, error)
    }

    @Test fun cancellationPropagatesWithoutBeingReclassifiedAsTimeout() {
        val cancelled = CancellationException("request cancelled")
        val future = object : CompletingFuture(0) {
            override fun get(timeout: Long, unit: TimeUnit): String = throw cancelled
        }
        val error = assertFailsWith<CancellationException> {
            NativeConversionAwait.await(future, "cancelled-output") { error("Cancellation must not be repeated") }
        }
        assertSame(cancelled, error)
    }
}
