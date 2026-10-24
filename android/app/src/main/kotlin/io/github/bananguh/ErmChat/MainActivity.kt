package io.github.bananguh.ErmChat

import android.app.ActivityManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Rational

import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // TTS engine selection is delegated to the system "Text-to-speech output"
    // screen (same as dankchat's ACTION_INSTALL_TTS_DATA flow), so we only need
    // an intent to open it.
    private val ttsChannelName = "ermchat/tts"
    private var ttsMethodChannel: MethodChannel? = null

    // Device facts: memory budgets (image cache, frame capture) and bug report
    // diagnostics; also the screen-edge area kept from the back gesture.
    private val deviceChannelName = "ermchat/device"

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "totalMemBytes" -> {
                        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                        val info = ActivityManager.MemoryInfo()
                        am.getMemoryInfo(info)
                        result.success(info.totalMem)
                    }
                    "deviceModel" -> result.success("${Build.MANUFACTURER} ${Build.MODEL}")
                    // [left, top, right, bottom] in window pixels, or null to
                    // give the edge back to the system.
                    "setGestureExclusion" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val r = call.argument<List<Int>>("rect")
                            window.decorView.systemGestureExclusionRects =
                                if (r == null) emptyList()
                                else listOf(Rect(r[0], r[1], r[2], r[3]))
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
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

    // Flutter drops its back callback whenever nothing can pop, which hands
    // back to the system default that finishes the activity. Keeping it
    // registered routes root back to popSystemNavigator instead.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setFrameworkHandlesBack(true)
    }

    override fun setFrameworkHandlesBack(frameworkHandlesBack: Boolean) {
        super.setFrameworkHandlesBack(true)
    }

    // Back at the root backgrounds the app like the home gesture instead of
    // finishing it, so returning keeps chat, connections and the stream.
    // A playing stream shrinks to PiP, as leaving by home does.
    override fun popSystemNavigator(): Boolean {
        if (pipAutoEnter && !isInPictureInPictureMode && enterPipNow()) return true
        moveTaskToBack(true)
        return true
    }

    // Auto-enter covers the home and recents gestures only. Leaving because
    // the app opened something else (a link, a share target) or a
    // notification was tapped lands here instead, so enter by hand.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (pipAutoEnter && !isInPictureInPictureMode) enterPipNow()
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
}
