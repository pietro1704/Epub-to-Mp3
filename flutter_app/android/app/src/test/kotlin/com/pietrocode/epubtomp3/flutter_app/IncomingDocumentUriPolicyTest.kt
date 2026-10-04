package com.pietrocode.epubtomp3.flutter_app

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class IncomingDocumentUriPolicyTest {
    @Test fun acceptsProviderUrisWithoutTreatingProviderPathAsFilesystemPath() {
        val policy = IncomingDocumentUriPolicy(listOf(File("/storage/emulated/0")))
        assertTrue(policy.isAllowed("content", "provider", "/document/../../data/data/app/files/book.epub"))
    }

    @Test fun acceptsExternalFileButRejectsPrivateFileAndOtherSchemes() {
        val root = createTempDirectory("incoming-document").toFile()
        val shared = File(root, "book.epub").apply { writeText("epub") }
        val privateFile = File(createTempDirectory("app-private").toFile(), "book.epub").apply { writeText("epub") }
        val policy = IncomingDocumentUriPolicy(listOf(root))
        assertTrue(policy.isAllowed("file", null, shared.path))
        assertFalse(policy.isAllowed("file", null, privateFile.path))
        assertFalse(policy.isAllowed("http", "example.test", "/book.epub"))
    }
}