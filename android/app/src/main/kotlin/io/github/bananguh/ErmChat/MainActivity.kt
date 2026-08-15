package io.github.bananguh.ErmChat

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import androidx.browser.customtabs.CustomTabsServiceConnection
import androidx.browser.customtabs.CustomTabsSession
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ermchat/oauth"
    private var methodChannel: MethodChannel? = null
    private var customTabsSession: CustomTabsSession? = null
    private var pendingUrl: String? = null
    private var pendingRedirect: String? = null

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
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleOAuthIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleOAuthIntent(intent)
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
