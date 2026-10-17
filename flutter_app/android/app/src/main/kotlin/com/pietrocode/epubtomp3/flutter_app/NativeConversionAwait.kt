package com.pietrocode.epubtomp3.flutter_app

import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Keep foreground JNI waiting finite without changing its cancellation owner. */
internal object NativeConversionAwait {
    const val TIMEOUT_SECONDS = 3600L

    fun <T> await(future: Future<T>, outputPath: String, cancelNative: (String) -> Unit): T = try {
        future.get(TIMEOUT_SECONDS, TimeUnit.SECONDS)
    } catch (timeout: TimeoutException) {
        cancelNative(outputPath)
        future.cancel(true)
        throw timeout
    }
}
