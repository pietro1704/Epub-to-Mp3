package com.pietrocode.epubtomp3.flutter_app

import android.net.Uri
import java.io.File

internal class IncomingDocumentUriPolicy(private val allowedFileRoots: List<File>) {
    fun isAllowed(uri: Uri): Boolean = isAllowed(uri.scheme, uri.authority, uri.path)

    fun isAllowed(scheme: String?, authority: String?, path: String?): Boolean = when (scheme?.lowercase()) {
        "content" -> !authority.isNullOrBlank()
        "file" -> path?.let(::allowedFile) == true
        else -> false
    }

    private fun allowedFile(path: String): Boolean = try {
        val file = File(path).canonicalFile
        file.isFile && file.canRead() && allowedFileRoots.any { root ->
            val rootPath = root.canonicalPath
            file.path == rootPath || file.path.startsWith(rootPath + File.separator)
        }
    } catch (_: Exception) { false }
}