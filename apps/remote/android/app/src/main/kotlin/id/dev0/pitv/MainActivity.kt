package id.dev0.pitv

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Receives YouTube links shared to the app (ACTION_SEND text/plain and
 * text/uri-list) or opened with it (ACTION_VIEW) and hands the raw text to
 * Dart, which parses it with the shared YouTube URL parser.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingShare: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) pendingShare = extractShare(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pi_tv/share").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialShare" -> {
                        result.success(pendingShare)
                        pendingShare = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractShare(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("shareReceived", text) else pendingShare = text
    }

    private fun extractShare(intent: Intent?): String? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
                @Suppress("DEPRECATION")
                val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.toString()
                listOfNotNull(subject, text, stream).joinToString("\n").ifBlank { null }
            }
            Intent.ACTION_VIEW -> intent.dataString
            else -> null
        }
    }
}
