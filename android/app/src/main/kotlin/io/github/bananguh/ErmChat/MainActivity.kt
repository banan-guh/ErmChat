package io.github.bananguh.ErmChat

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Rational

import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import androidx.browser.customtabs.CustomTabsServiceConnection
import androidx.browser.customtabs.CustomTabsSession
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ermchat/oauth"
    private var methodChannel: MethodChannel? = null
    private var customTabsSession: CustomTabsSession? = null
    private var pendingUrl: String? = null
    private var pendingRedirect: String? = null

    // TTS engine selection is delegated to the system "Text-to-speech output"
    // screen (same as dankchat's ACTION_INSTALL_TTS_DATA flow), so we only need
    // an intent to open it.
    private val ttsChannelName = "ermchat/tts"
    private var ttsMethodChannel: MethodChannel? = null

    // System Picture-in-Picture for the stream player (DankChat pattern, no
    // plugin): Dart drives `setAutoEnter` from player state and calls
    // `enterPip` for the overlay button; mode changes flow back as
    // `onPipChanged` so the UI can collapse to video-only. The PiP window
    // gets a play/pause action via `updateActions`; taps arrive as
    // `onPipAction` and Dart forwards them to the WebView player.
    private val pipChannelName = "ermchat/pip"
    private var pipMethodChannel: MethodChannel? = null
    private var pipAutoEnter = false
    private var pipPlaying = true
    private var pipReceiverRegistered = false

    private val pipActionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_PIP_CONTROL) return
            val action = when (intent.getIntExtra(EXTRA_PIP_CONTROL, 0)) {
                CONTROL_PIP_PLAY -> "play"
                CONTROL_PIP_PAUSE -> "pause"
                else -> return
            }
            pipMethodChannel?.invokeMethod("onPipAction", action)
        }
    }

    companion object {
        private const val ACTION_PIP_CONTROL = "io.github.bananguh.ErmChat.PIP_CONTROL"
        private const val EXTRA_PIP_CONTROL = "control_type"
        private const val CONTROL_PIP_PLAY = 1
        private const val CONTROL_PIP_PAUSE = 2
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "launchCustomTab" -> {
                    val url = call.argument<String>("url")
                    if (url == null) {
                        result.error("NO_URL", "No url provided", null)
                    } else {
                        launchInCustomTab(url)
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // A deep link that arrived before the engine was ready (cold start).
        pendingRedirect?.let {
            methodChannel?.invokeMethod("onRedirect", it)
            pendingRedirect = null
        }
        ttsMethodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttsChannelName)
        ttsMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "openTtsSettings" -> {
                    try {
                        startActivity(Intent("com.android.settings.TTS_SETTINGS"))
                    } catch (_: Exception) {
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        pipMethodChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
        pipMethodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(isPipSupported())
                "setAutoEnter" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setPipAutoEnter(enabled)
                    result.success(null)
                }
                "enterPip" -> result.success(enterPipNow())
                "updateActions" -> {
                    pipPlaying = call.argument<Boolean>("playing") ?: true
                    applyPipParams()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleOAuthIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleOAuthIntent(intent)
    }

    // Both overloads: the single-arg version is deprecated since API 26 and
    // is not reliably called on newer releases, so the two-arg version is
    // the one that actually fires. Dart dedupes via setPipActive anyway.
    @Deprecated("Use the two-arg overload on API 26+")
    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode)
        notifyPipChanged(isInPictureInPictureMode)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        notifyPipChanged(isInPictureInPictureMode)
    }

    private fun notifyPipChanged(inPip: Boolean) {
        if (inPip) {
            if (!pipReceiverRegistered) {
                pipReceiverRegistered = true
                ContextCompat.registerReceiver(
                    this,
                    pipActionReceiver,
                    IntentFilter(ACTION_PIP_CONTROL),
                    ContextCompat.RECEIVER_NOT_EXPORTED,
                )
            }
        } else if (pipReceiverRegistered) {
            pipReceiverRegistered = false
            try {
                unregisterReceiver(pipActionReceiver)
            } catch (_: Exception) {
            }
        }
        pipMethodChannel?.invokeMethod("onPipChanged", inPip)
    }

    private fun isPipSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    private fun setPipAutoEnter(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        pipAutoEnter = enabled
        applyPipParams()
    }

    private fun enterPipNow(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            enterPictureInPictureMode(pipParamsBuilder().build())
        } catch (_: Exception) {
            false
        }
    }

    // Single builder so aspect, auto-enter, and window actions never
    // overwrite each other (each setPictureInPictureParams call replaces
    // the whole set). Safe to call outside PiP; takes effect on entry.
    private fun pipParamsBuilder(): PictureInPictureParams.Builder {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipAutoEnter)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setActions(pipActions())
        }
        return builder
    }

    private fun applyPipParams() {
        try {
            setPictureInPictureParams(pipParamsBuilder().build())
        } catch (_: Exception) {
        }
    }

    // Play/pause flips with playback state (Dart reports it). One slot:
    // the audio action waits for the audio-only release.
    private fun pipActions(): ArrayList<RemoteAction> {
        val actions = ArrayList<RemoteAction>()
        val playRes = if (pipPlaying) R.drawable.ic_pip_pause else R.drawable.ic_pip_play
        val playControl = if (pipPlaying) CONTROL_PIP_PAUSE else CONTROL_PIP_PLAY
        val playLabel = if (pipPlaying) "Pause" else "Play"
        actions.add(pipAction(playRes, playLabel, playControl, playControl))
        return actions
    }

    private fun pipAction(res: Int, label: String, control: Int, requestCode: Int): RemoteAction {
        val intent = Intent(ACTION_PIP_CONTROL).apply {
            setPackage(packageName)
            putExtra(EXTRA_PIP_CONTROL, control)
        }
        val pending = PendingIntent.getBroadcast(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return RemoteAction(Icon.createWithResource(this, res), label, label, pending)
    }

    private fun handleOAuthIntent(intent: Intent) {
        val data = intent.data
        if (data != null && data.scheme == "ermchat") {
            if (methodChannel != null) {
                methodChannel?.invokeMethod("onRedirect", data.toString())
            } else {
                pendingRedirect = data.toString()
            }
        }
    }

    private fun launchInCustomTab(url: String) {
        val pkg = CustomTabsClient.getPackageName(this, null)
        if (pkg == null) {
            // No browser supports Custom Tabs: fall back to a plain view intent.
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            return
        }
        pendingUrl = url
        CustomTabsClient.bindCustomTabsService(
            this,
            pkg,
            object : CustomTabsServiceConnection() {
                override fun onCustomTabsServiceConnected(
                    name: ComponentName,
                    client: CustomTabsClient,
                ) {
                    client.warmup(0)
                    customTabsSession = client.newSession(null)
                    val toLaunch = pendingUrl ?: return
                    pendingUrl = null
                    // A session-bound CustomTabsIntent forces every navigation
                    // inside this tab to stay in the tab, even for URLs the OS
                    // would otherwise hand to a verified native app (e.g. the
                    // Twitch app owning id.twitch.tv). Documented Custom Tabs
                    // behavior; this is what keeps the whole OAuth flow
                    // (including the "not you? log out" interstitial) in the
                    // browser instead of kicking out to the Twitch app.
                    val intent =
                        CustomTabsIntent.Builder(customTabsSession!!).build()
                    intent.launchUrl(this@MainActivity, Uri.parse(toLaunch))
                }

                override fun onServiceDisconnected(name: ComponentName) {
                    customTabsSession = null
                }
            },
        )
    }
}
