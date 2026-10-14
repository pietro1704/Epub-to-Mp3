package com.pietrocode.epubtomp3.flutter_app

import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

/** Serialize an engine without hiding cancellation behind a monitor wait. */
internal class SpeechRequestGate {
    private val lock = ReentrantLock()

    fun <T> withPermit(cancelled: () -> Boolean, action: () -> T): T {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(120)
        while (true) {
            check(!Thread.currentThread().isInterrupted && !cancelled()) { "Queued speech request cancelled" }
            check(System.nanoTime() < deadline) { "Queued speech request timed out" }
            if (lock.tryLock(25, TimeUnit.MILLISECONDS)) break
        }
        try {
            check(!cancelled()) { "Queued speech request cancelled" }
            return action()
        } finally {
            lock.unlock()
        }
    }
}
