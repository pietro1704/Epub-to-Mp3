package com.pietrocode.epubtomp3.flutter_app

import java.util.concurrent.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

/** Prepare the Rust control before publishing a cancellable native request. */
internal class BackgroundNativeExecution(
    private val prepare: (String) -> Unit,
    private val cancel: (String) -> Boolean,
) {
    @Volatile private var activeOutput: String? = null
    @Volatile private var stopped = false

    fun stop() {
        stopped = true
        activeOutput?.let { cancel(it) }
    }

    fun <T> run(outputPath: String, checkActive: () -> Unit, action: () -> T): T {
        prepare(outputPath)
        activeOutput = outputPath
        try {
            checkActive()
            if (stopped) throw CancellationException("Background conversion stopped before native execution")
            val result = action()
            checkActive()
            if (stopped) throw CancellationException("Background conversion stopped during native execution")
            return result
        } catch (cancelled: CancellationException) {
            cancel(outputPath)
            throw cancelled
        } finally { activeOutput = null }
    }
}

/** CoroutineWorker.onStopped is final; a sibling observes cancellation while JNI blocks IO. */
internal suspend fun <T> watchBackgroundNativeCancellation(execution: BackgroundNativeExecution, action: suspend () -> T): T = coroutineScope {
    val watcher = launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
        try { awaitCancellation() } finally { execution.stop() }
    }
    try { action() } finally { watcher.cancel() }
}
