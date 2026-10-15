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
        val options = JSONObject(raw ?: "{\"tts_preferences\":{\"primary\":{\"engine\":\"piper\",\"model_id\":\"pt_BR-faber-medium\"},\"secondary\":null,\"allow_online_fallback\":false}}")
        val preferences = options.optJSONObject("tts_preferences")
        val needsPiper = preferences?.optJSONObject("primary")?.optString("engine") == "piper" || preferences?.optJSONObject("secondary")?.optString("engine") == "piper"
        if (needsPiper) {
            val dataParent = installEspeakAssets(context.filesDir,
                { path -> context.assets.list(path) ?: emptyArray() },
                { path -> context.assets.open(path) })
            options.put("espeak_data_directory", dataParent.absolutePath)
        }
        return options.toString()
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
