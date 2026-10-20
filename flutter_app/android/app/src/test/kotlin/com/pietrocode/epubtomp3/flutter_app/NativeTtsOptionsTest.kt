package com.pietrocode.epubtomp3.flutter_app

import java.io.ByteArrayInputStream
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import java.util.concurrent.CancellationException

class NativeTtsOptionsTest {
    @Test fun unavailableAssetsAllowOnlyOptedInNativeFallback() {
        assertNull(NativeTtsOptions.installedPiperAssets(true) { throw java.io.IOException("Missing packaged assets") })
        assertFailsWith<java.io.IOException> {
            NativeTtsOptions.installedPiperAssets(false) { throw java.io.IOException("Missing packaged assets") }
        }
        assertFailsWith<CancellationException> {
            NativeTtsOptions.installedPiperAssets(true) { throw CancellationException("Stopped") }
        }
    }
    @Test fun successfulAssetPreparationPreservesTheActualRoot() {
        val root = java.io.File("/test/native-assets")
        assertEquals(root, NativeTtsOptions.installedPiperAssets(true) { root })
    }
    @Test fun extractsCompleteTreeAndReturnsEspeakParent() {
        val parent = Files.createTempDirectory("espeak-assets-").toFile()
        val assets = mapOf(
            "espeak-ng-data/phontab" to "phonemes",
            "espeak-ng-data/lang/roa/pt" to "Portuguese",
            "espeak-ng-data/lang/gmw/en" to "English",
        )
        try {
            val dataParent = NativeTtsOptions.installEspeakAssets(parent, { path ->
                assets.keys.filter { it.startsWith("$path/") }
                    .map { it.removePrefix("$path/").substringBefore('/') }.distinct().toTypedArray()
            }, { path -> ByteArrayInputStream(checkNotNull(assets[path]).toByteArray()) })
            assertEquals(parent.absolutePath, dataParent.absolutePath)
            assertTrue(dataParent.resolve("espeak-ng-data/phontab").isFile)
            assertEquals("Portuguese", dataParent.resolve("espeak-ng-data/lang/roa/pt").readText())
            assertEquals("English", dataParent.resolve("espeak-ng-data/lang/gmw/en").readText())
            assertTrue(parent.walkTopDown().none { it.name.endsWith(".part") })
        } finally { parent.deleteRecursively() }
    }
}
