package com.pietrocode.epubtomp3.flutter_app

import android.content.Intent
import android.os.Bundle

import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import java.io.File

/** Activity lifecycle and stable JNI declaration owner. */
class MainActivity : AudioServiceActivity() {
    private val platformSpeech by lazy { PlatformSpeechProvider(this) }
    private val conversionChannels by lazy { FlutterConversionChannels(this) }
    private val incomingDocuments by lazy { IncomingDocumentIntake(this, conversionChannels.executor) }
    private val listeningSpeech by lazy { AndroidListeningSpeechChannel(this) }

    // Called synchronously by Rust on a worker thread. The cancellation context
    // is borrowed for this call only and must never escape into Android callbacks.
    fun synthesizeNativeSpeech(text: String, language: String, path: String, inputPath: String, cancelContext: Long): Boolean {
        platformSpeech.synthesize(text, language, path, { nativePlatformSpeechCancelled(cancelContext) }) {
            conversionChannels.platformVoiceEvents?.success(mapOf("engine" to "system", "inputPath" to inputPath))
        }
        return true
    }

    // This callback name and its JVM signature are part of the Rust JNI ABI.
    fun onNativeAudioChunk(requestId: String, chapterIndex: Int, chunkIndex: Int, path: String): Boolean =
        conversionChannels.onNativeAudioChunk(requestId, chapterIndex, chunkIndex, path)

    external fun nativePlatformSpeechCancelled(context: Long): Boolean
    external fun nativePrepareConversion(request: String)
    external fun nativeCancelConversion(request: String)

    companion object {
        private const val CHANNEL = "epub_to_mp3/embedded_rust"
        private const val EMBEDDED_CHANNEL = "epub_to_mp3/embedded_converter"
        private const val EMBEDDED_UNAVAILABLE = "EMBEDDED_CONVERTER_UNAVAILABLE"
        private const val CONVERTER_LIBRARY = "converter_ffi"
        internal var converterLibraryLoaded = false

        init {
            // Native libraries are loaded lazily before the first conversion.
        }

        internal fun converterLibraryAvailable(): Boolean {
            // The packaged converter is Edge-only on legacy Android devices.
            // Piper remains a separately gated local runtime and is never
            // loaded here on API 28.
            return try {
                if (!converterLibraryLoaded) {
                    System.loadLibrary(CONVERTER_LIBRARY)
                    converterLibraryLoaded = true
                }
                converterLibraryLoaded
            } catch (_: UnsatisfiedLinkError) {
                false
            }
        }

        private fun registerEmbeddedPiper() {
            // The native converter resolves the Piper runtime directly from
            // its linked library; no JNI symbol is required for registration.
        }
    }

    internal fun embeddedConverterStatus(): Map<String, Boolean> = try {
        converterLibraryAvailable()
        val modelAvailable = installedLocalModel() != null
        mapOf(
            "runtimeLoaded" to converterLibraryLoaded,
            "modelAvailable" to modelAvailable,
            "abiCompatible" to converterLibraryLoaded,
            // Edge is the online default and does not require a local model.
            "engineReady" to converterLibraryLoaded,
        )
    } catch (_: Throwable) {
        mapOf(
            "runtimeLoaded" to false,
            "modelAvailable" to false,
            "abiCompatible" to false,
            "engineReady" to false,
        )
    }

    private fun installedLocalModel(): String? {
        val root = File(filesDir, "tts-models")
        return root.listFiles()
            ?.asSequence()
            ?.flatMap { directory ->
                sequenceOf(
                    File(directory, "model.onnx"),
                    File(directory, "model.bin"),
                )
            }
            ?.firstOrNull { it.isFile }
            ?.absolutePath
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        incomingDocuments.handleIncomingIntent(intent)

    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingDocuments.handleIncomingIntent(intent)
    }

    @Deprecated("Deprecated in Android API Activity, retained for API 28 compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        incomingDocuments.onActivityResult(requestCode, resultCode, data)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // AudioServiceActivity supplies audio_service's shared engine. Register
        // only this activity's channels on that engine; do not create or cache
        // another engine here.
        super.configureFlutterEngine(flutterEngine)
        incomingDocuments.configure(flutterEngine)
        listeningSpeech.configure(flutterEngine)
        conversionChannels.configure(flutterEngine)
    }

    internal fun conversionOptions(raw: String?): String = NativeTtsOptions.prepare(applicationContext, raw)

    external fun nativeConvertWithOptions(inputPath: String, outputPath: String, chapterStart: Int, chapterEnd: Int, optionsJson: String, streaming: Boolean): String?
    external fun nativePiperSynthesizeWithOptions(text: String, output: String, optionsJson: String): Boolean
    external fun nativeParse(inputPath: String): String?
    external fun nativeJobLog(jobId: String): String?
    external fun nativeConvert(inputPath: String, outputPath: String, chapterStart: Int, chapterEnd: Int): String?
    external fun nativeConvertStreaming(inputPath: String, outputPath: String, chapterStart: Int, chapterEnd: Int): String?
    external fun nativeTtsModels(): String?
    external fun nativeTtsDefaultEngine(language: String, platform: String, androidApi: Int): String?
    external fun nativeTtsInstalledReadyEngine(language: String, platform: String, androidApi: Int, installedModelIdsJson: String, readyModelIdsJson: String): String?
    external fun nativeTtsModelInstall(modelId: String, url: String, sha256: String, root: String): String?
    external fun nativeTtsModelInstallManifest(modelId: String, artifactsJson: String, root: String): String?
    external fun nativeTtsModelInstallCatalogManifest(modelId: String, root: String): String?
    external fun nativePiperSynthesize(text: String, output: String): Boolean
    external fun nativeTtsModelMetadata(modelId: String, root: String): String?
    external fun nativeTtsModelRemove(modelId: String, root: String): Boolean

    external fun nativeLastError(): String

    override fun onDestroy() {
        conversionChannels.close()
        incomingDocuments.close()
        listeningSpeech.close()
        platformSpeech.close()
        super.onDestroy()
    }
}
