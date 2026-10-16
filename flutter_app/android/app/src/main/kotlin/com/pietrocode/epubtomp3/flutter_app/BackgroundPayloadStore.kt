package com.pietrocode.epubtomp3.flutter_app

import java.io.File
import java.util.UUID

/** One immutable snapshot per WorkRequest, including requests ignored by KEEP. */
internal object BackgroundPayloadStore {
    fun persist(directory: File, jobId: String, payload: String, requestId: UUID = UUID.randomUUID()): File {
        check(directory.exists() || directory.mkdirs()) { "Could not create background payload directory" }
        val prefix = jobId.replace(Regex("[^A-Za-z0-9_-]"), "_").take(64)
        val target = File(directory, "$prefix-$requestId.json")
        // Reserve this unique name before publishing; an existing request must never be overwritten.
        check(target.createNewFile()) { "Background request snapshot already exists" }
        val temporary = File(directory, ".${target.name}.part")
        try {
            temporary.writeText(payload, Charsets.UTF_8)
            check(temporary.renameTo(target)) { "Could not atomically publish background payload" }
            return target
        } catch (error: Exception) {
            target.delete()
            throw error
        } finally { temporary.delete() }
    }
}
