package com.pietrocode.epubtomp3.flutter_app

import java.nio.file.Files
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class BackgroundPayloadStoreTest {
    @Test fun sameJobReenqueueNeverChangesThePendingRequestsVoiceSnapshot() {
        val directory = Files.createTempDirectory("background-snapshot-").toFile()
        try {
            val first = BackgroundPayloadStore.persist(directory, "same-job", "Faber chapter 0; online fallback disabled")
            val second = BackgroundPayloadStore.persist(directory, "same-job", "Edge chapter 5; online fallback enabled")
            assertNotEquals(first.path, second.path)
            assertEquals("Faber chapter 0; online fallback disabled", first.readText())
            assertEquals("Edge chapter 5; online fallback enabled", second.readText())
            assertTrue(directory.listFiles().orEmpty().none { it.name.endsWith(".part") })
        } finally { directory.deleteRecursively() }
    }

    @Test fun anExistingRequestIdentityCannotBeOverwritten() {
        val directory = Files.createTempDirectory("background-id-collision-").toFile()
        val request = UUID.randomUUID()
        try {
            val original = BackgroundPayloadStore.persist(directory, "job", "original immutable options", request)
            assertFailsWith<IllegalStateException> {
                BackgroundPayloadStore.persist(directory, "job", "changed options", request)
            }
            assertEquals("original immutable options", original.readText())
        } finally { directory.deleteRecursively() }
    }

    @Test fun nativeReceiptsRetainOpaquePolicyAndActualVoiceWithoutParsing() {
        val directory = Files.createTempDirectory("background-receipt-").toFile()
        val nativeResult = "{\"manifest\":{\"ttsPolicyState\":{\"opaque\":\"rust-state\"},\"fallbackUsed\":true,\"usedSelections\":[{\"engine\":\"edge\",\"voice\":\"pt-BR-FranciscaNeural\"}]}}"
        try {
            val receipt = BackgroundPayloadStore.persist(directory, "background-result-work-id", nativeResult)
            assertEquals(nativeResult, receipt.readText())
        } finally { directory.deleteRecursively() }
    }
}
