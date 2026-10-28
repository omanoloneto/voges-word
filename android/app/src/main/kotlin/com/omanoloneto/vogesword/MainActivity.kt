package com.omanoloneto.vogesword

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val pending = mutableListOf<Map<String, Any?>>()
    private var dartReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voges_word/open").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "pending") {
                    dartReady = true
                    result.success(pending.toList())
                    pending.clear()
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "voges_word/print").setMethodCallHandler { call, result ->
            val bytes = call.argument<ByteArray>("bytes")
            if (call.method != "print" || bytes == null) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val name = call.argument<String>("name") ?: "Documento"
            val manager = getSystemService(Context.PRINT_SERVICE) as PrintManager
            manager.print(name, PdfPrintAdapter(bytes, name), PrintAttributes.Builder().build())
            result.success(null)
        }
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val file = read(intent.data ?: return) ?: return
        if (dartReady) channel?.invokeMethod("open", listOf(file)) else pending.add(file)
    }

    private fun read(uri: Uri): Map<String, Any?>? = try {
        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
        bytes?.let { mapOf("name" to displayName(uri), "bytes" to it) }
    } catch (error: Exception) {
        null
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return uri.lastPathSegment ?: "Documento.docx"
    }
}

/** Entrega ao serviço de impressão o PDF que o app já montou. */
private class PdfPrintAdapter(private val bytes: ByteArray, private val name: String) : PrintDocumentAdapter() {
    override fun onLayout(
        oldAttributes: PrintAttributes?,
        newAttributes: PrintAttributes,
        cancellationSignal: CancellationSignal?,
        callback: LayoutResultCallback,
        extras: Bundle?,
    ) {
        if (cancellationSignal?.isCanceled == true) {
            callback.onLayoutCancelled()
            return
        }
        val info = PrintDocumentInfo.Builder("$name.pdf")
            .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
            .build()
        callback.onLayoutFinished(info, oldAttributes != newAttributes)
    }

    override fun onWrite(
        pages: Array<out PageRange>?,
        destination: ParcelFileDescriptor,
        cancellationSignal: CancellationSignal?,
        callback: WriteResultCallback,
    ) {
        try {
            FileOutputStream(destination.fileDescriptor).use { it.write(bytes) }
            callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
        } catch (error: Exception) {
            callback.onWriteFailed(error.message)
        }
    }
}
