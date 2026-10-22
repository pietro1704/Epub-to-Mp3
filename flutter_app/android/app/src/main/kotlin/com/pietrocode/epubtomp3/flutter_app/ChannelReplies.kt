package com.pietrocode.epubtomp3.flutter_app

import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/** Owns outstanding channel replies through activity teardown. */
internal class ChannelReplies {
    private val pending = mutableSetOf<Reply>()
    private var closed = false

    fun track(result: MethodChannel.Result): MethodChannel.Result {
        val reply = Reply(result)
        val rejected = synchronized(pending) {
            if (closed) true else {
                pending.add(reply)
                false
            }
        }
        if (rejected) reply.cancel()
        return reply
    }

    fun close() {
        val outstanding = synchronized(pending) {
            closed = true
            pending.toList().also { pending.clear() }
        }
        outstanding.forEach { it.cancel() }
    }

    private inner class Reply(private val delegate: MethodChannel.Result) : MethodChannel.Result {
        private val completed = AtomicBoolean(false)

        private fun finish(deliver: () -> Unit) {
            if (!completed.compareAndSet(false, true)) return
            synchronized(pending) { pending.remove(this) }
            deliver()
        }

        override fun success(result: Any?) = finish { delegate.success(result) }

        override fun error(code: String, message: String?, details: Any?) =
            finish { delegate.error(code, message, details) }

        override fun notImplemented() = finish { delegate.notImplemented() }

        fun cancel() = error("ACTIVITY_DESTROYED", "Activity closed before the request completed", null)
    }
}
