package com.pietrocode.epubtomp3.flutter_app

import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

/** Runs the ML Kit OCR in the minified (R8) build: shrinking must not strip its internals. */
class PdfPageOcrR8Test {
    @Test
    fun recognizesTextDrawnOnAPdfPage() {
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        val pdf = File(dir, "ocr-r8-synthetic.pdf")
        val document = PdfDocument()
        val page = document.startPage(PdfDocument.PageInfo.Builder(595, 842, 1).create())
        page.canvas.drawColor(Color.WHITE)
        val paint = Paint().apply {
            color = Color.BLACK
            textSize = 28f
            isAntiAlias = true
        }
        page.canvas.drawText("The quick brown fox", 40f, 120f, paint)
        page.canvas.drawText("jumps over the lazy dog", 40f, 180f, paint)
        document.finishPage(page)
        pdf.outputStream().use { document.writeTo(it) }
        document.close()
        try {
            Log.i("PdfPageOcrR8Test", "Starting recognition of the synthetic PDF")
            val text = PdfPageOcr.recognize(pdf.path, 1).lowercase()
            Log.i("PdfPageOcrR8Test", "Recognition returned ${text.length} characters")
            assertTrue("quick" in text && "lazy" in text, "OCR text was: $text")
        } finally {
            pdf.delete()
        }
    }
}
