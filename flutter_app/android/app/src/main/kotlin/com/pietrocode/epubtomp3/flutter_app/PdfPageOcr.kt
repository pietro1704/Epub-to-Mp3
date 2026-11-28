package com.pietrocode.epubtomp3.flutter_app

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.io.File

/** Renders one PDF page and reads it with the on-device ML Kit recognizer (blocking). */
internal object PdfPageOcr {
    private const val TARGET_WIDTH = 1600

    fun recognize(path: String, page: Int): String {
        ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
            PdfRenderer(fd).use { renderer ->
                require(page in 1..renderer.pageCount) { "page $page is outside 1..${renderer.pageCount}" }
                renderer.openPage(page - 1).use { pdfPage ->
                    val scale = TARGET_WIDTH.toFloat() / pdfPage.width
                    val bitmap = Bitmap.createBitmap(
                        TARGET_WIDTH,
                        (pdfPage.height * scale).toInt().coerceAtLeast(1),
                        Bitmap.Config.ARGB_8888,
                    )
                    bitmap.eraseColor(Color.WHITE)
                    pdfPage.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
                    try {
                        return Tasks.await(recognizer.process(InputImage.fromBitmap(bitmap, 0))).text
                    } finally {
                        recognizer.close()
                        bitmap.recycle()
                    }
                }
            }
        }
    }
}
