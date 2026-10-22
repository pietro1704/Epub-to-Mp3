package com.pietrocode.epubtomp3.flutter_app

import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals

class ChannelRepliesTest {
    private class RecordedReply : MethodChannel.Result {
        val deliveries = mutableListOf<Pair<String, Any?>>()
        override fun success(result: Any?) { deliveries.add("success" to result) }
        override fun error(code: String, message: String?, details: Any?) {
            deliveries.add(code to details)
        }
        override fun notImplemented() { deliveries.add("missing" to null) }
    }

    @Test fun nativeCompletionAndLateErrorCompleteOnlyOnce() {
        val replies = ChannelReplies()
        val first = RecordedReply()
        val second = RecordedReply()
        val firstRequest = replies.track(first)
        val secondRequest = replies.track(second)
        firstRequest.success("manifest-a")
        firstRequest.error("LATE_ERROR", "late callback", null)
        secondRequest.error("NATIVE_FAILED", "failure", "request-b")
        replies.close()
        assertEquals(listOf<Pair<String, Any?>>("success" to "manifest-a"), first.deliveries)
        assertEquals(listOf<Pair<String, Any?>>("NATIVE_FAILED" to "request-b"), second.deliveries)
    }

    @Test fun destructionCancelsPendingAndRejectsNewRequestsWithoutDuplicates() {
        val replies = ChannelReplies()
        val pending = RecordedReply()
        val request = replies.track(pending)
        replies.close()
        replies.close()
        request.success("stale manifest")
        val late = RecordedReply()
        replies.track(late).notImplemented()
        assertEquals(listOf<Pair<String, Any?>>("ACTIVITY_DESTROYED" to null), pending.deliveries)
        assertEquals(listOf<Pair<String, Any?>>("ACTIVITY_DESTROYED" to null), late.deliveries)
    }

    @Test fun competingTerminalCallbacksDeliverOnlyOneResult() {
        val replies = ChannelReplies()
        val recorded = RecordedReply()
        val request = replies.track(recorded)
        val workers = Executors.newFixedThreadPool(2)
        try {
            val completions = (0 until 20).map { index ->
                workers.submit { request.success(index) }
            }
            completions.forEach { it.get(1, TimeUnit.SECONDS) }
            assertEquals(1, recorded.deliveries.size)
        } finally {
            replies.close()
            workers.shutdownNow()
        }
    }
}
