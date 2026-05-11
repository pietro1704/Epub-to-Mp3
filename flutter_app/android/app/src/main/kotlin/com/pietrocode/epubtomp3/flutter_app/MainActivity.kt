package com.pietrocode.epubtomp3.flutter_app

import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter activity and exposes a MethodChannel that bridges Dart
 * to the embedded CPython runtime (Chaquopy) running python_app.src.
 *
 * Mirrors the iOS PythonKit bridge — keep the channel name and method
 * names in sync with `flutter_app/lib/services/python_bridge.dart` and
 * the iOS `PythonBridge.swift` so both clients share the contract.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "epub_to_mp3/python"
        private const val PY_MODULE = "python_app.src.android_entrypoints"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Chaquopy needs to be started exactly once per process.
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                val py = Python.getInstance()
                val entrypoints = py.getModule(PY_MODULE)
                when (call.method) {
                    "bootstrap" -> {
                        val version = entrypoints.callAttr("bootstrap").toString()
                        result.success(version)
                    }
                    "parseEpub" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error(
                                "BAD_ARGS",
                                "parseEpub requires a non-empty 'path' argument",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        val json = entrypoints
                            .callAttr("parse_epub_to_json", path)
                            .toString()
                        result.success(json)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error(
                    "PYTHON_ERROR",
                    e.message ?: e.javaClass.simpleName,
                    e.stackTraceToString()
                )
            }
        }
    }
}
