package com.omanoloneto.vogesword

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
