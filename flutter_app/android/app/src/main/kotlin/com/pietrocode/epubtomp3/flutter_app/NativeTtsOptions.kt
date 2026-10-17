package com.pietrocode.epubtomp3.flutter_app

import android.content.Context
import android.system.Os
import java.io.File
import org.json.JSONObject

/** Asset delivery is explicit packaging; it never downloads a model. */
object NativeTtsOptions {
    @Synchronized fun prepare(context: Context, raw: String?): String {
        // Rust's Android default (/data/local/tmp) is not writable by app UIDs.
        // Foreground and WorkManager conversions must share the app cache path.
        val temporaryDirectory = context.cacheDir
        check(temporaryDirectory.isDirectory || temporaryDirectory.mkdirs()) { "Cannot create native temporary directory" }
        Os.setenv("TMPDIR", temporaryDirectory.absolutePath, true)
        val options = JSONObject(raw ?: "{\"tts_preferences\":{\"primary\":{\"engine\":\"piper\",\"model_id\":\"pt_BR-faber-medium\"},\"secondary\":{\"engine\":\"system\"},\"allow_online_fallback\":false,\"policy_version\":2}}")
        val preferences = options.optJSONObject("tts_preferences")
        val needsPiper = preferences?.optJSONObject("primary")?.optString("engine") == "piper" || preferences?.optJSONObject("secondary")?.optString("engine") == "piper"
        if (needsPiper) {
            preparePiperAssets(options) {
                installEspeakAssets(context.filesDir,
                    { path -> context.assets.list(path) ?: emptyArray() },
                    { path -> context.assets.open(path) })
            }
        }
        return options.toString()
    }

    /** Unavailable packaged Piper assets must not preempt an opted-in native fallback. */
    internal fun preparePiperAssets(options: JSONObject, install: () -> File) {
        val policy = options.optJSONObject("tts_preferences")
        val mayFallback = policy?.optInt("policy_version", 1) == 2 &&
            policy.optJSONObject("primary")?.optString("engine") == "piper" &&
            policy.optJSONObject("secondary")?.optString("engine") == "system"
        val installed = installedPiperAssets(mayFallback, install)
        if (installed == null) options.remove("espeak_data_directory")
        else options.put("espeak_data_directory", installed.absolutePath)
    }

    internal fun installedPiperAssets(allowNativeFallback: Boolean, install: () -> File): File? {
        try {
            return install()
        } catch (failure: Exception) {
            if (failure is java.util.concurrent.CancellationException || !allowNativeFallback) throw failure
            return null
        }
    }

    /** eSpeak receives the parent containing espeak-ng-data, not the data folder itself. */
    internal fun installEspeakAssets(parent: File, list: (String) -> Array<String>, open: (String) -> java.io.InputStream): File {
        fun extract(path: String, target: File) {
            val children = list(path)
            if (children.isEmpty()) {
                target.parentFile?.mkdirs()
                if (!target.exists() || target.length() == 0L) {
                    val temporary = File(target.parentFile, ".${target.name}.part")
                    try {
                        open(path).use { input -> temporary.outputStream().use { input.copyTo(it) } }
                        check(temporary.renameTo(target)) { "Could not publish packaged eSpeak asset: $path" }
                    } finally { temporary.delete() }
                }
            } else {
                target.mkdirs()
                children.forEach { extract("$path/$it", File(target, it)) }
            }
        }
        extract("espeak-ng-data", File(parent, "espeak-ng-data"))
        return parent
    }
}
