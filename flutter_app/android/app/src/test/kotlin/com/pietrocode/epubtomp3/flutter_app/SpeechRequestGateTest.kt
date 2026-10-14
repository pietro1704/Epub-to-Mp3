package com.pietrocode.epubtomp3.flutter_app

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SpeechRequestGateTest {
    @Test fun cancelsQueuedRequestBeforeCurrentSynthesisCompletes() {
        val gate = SpeechRequestGate()
        val pool = Executors.newFixedThreadPool(2)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val queued = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        try {
            val current = pool.submit { gate.withPermit({ false }) { entered.countDown(); release.await() } }
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            val next = pool.submit<String> {
                try {
                    gate.withPermit({ queued.countDown(); cancelled.get() }) { "unexpected" }
                } catch (error: IllegalStateException) {
                    error.message.orEmpty()
                }
            }
            assertTrue(queued.await(1, TimeUnit.SECONDS))
            cancelled.set(true)
            assertEquals("Queued speech request cancelled", next.get(1, TimeUnit.SECONDS))
            assertEquals(1L, release.count)
            release.countDown()
            current.get(1, TimeUnit.SECONDS)
            assertEquals("next", gate.withPermit({ false }) { "next" })
        } finally {
            release.countDown()
            pool.shutdownNow()
        }
    }
}
