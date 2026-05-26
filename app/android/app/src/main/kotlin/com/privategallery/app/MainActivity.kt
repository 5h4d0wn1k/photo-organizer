package com.privategallery.app

import android.content.Intent
import android.content.pm.ApplicationInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val launchInviteChannelName = "private_gallery/launch_invite"
    private var launchInviteChannel: MethodChannel? = null
    private var pendingInvite: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingInvite = inviteFromIntent(intent)
        launchInviteChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            launchInviteChannelName,
        )
        launchInviteChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeInitialInvite" -> {
                    val invite = pendingInvite
                    pendingInvite = null
                    result.success(invite)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val invite = inviteFromIntent(intent) ?: return
        val channel = launchInviteChannel
        if (channel == null) {
            pendingInvite = invite
        } else {
            channel.invokeMethod("privateGalleryInvite", invite)
        }
    }

    private fun inviteFromIntent(intent: Intent?): Map<String, Any?>? {
        if (intent == null) {
            return null
        }

        val extras = intent.extras
        val explicitPayload = extras?.getString(EXTRA_PAIRING_PAYLOAD)
        val sharedPayload = if (
            explicitPayload.isNullOrBlank() &&
            Intent.ACTION_SEND == intent.action &&
            intent.type?.startsWith("text/") == true
        ) {
            extras?.getString(Intent.EXTRA_TEXT)
        } else {
            null
        }
        val payload = firstNonBlank(explicitPayload, sharedPayload)
        val desktopUrl = firstNonBlank(extras?.getString(EXTRA_DESKTOP_URL))
        val bearerToken = if (isDebuggable()) {
            firstNonBlank(extras?.getString(EXTRA_BEARER_TOKEN))
        } else {
            null
        }
        val deviceName = firstNonBlank(extras?.getString(EXTRA_DEVICE_NAME))
        val autoPair = extras?.getBoolean(EXTRA_AUTO_PAIR, false) ?: false

        if (payload == null && desktopUrl == null && bearerToken == null) {
            return null
        }

        return mapOf(
            "pairingPayload" to payload,
            "desktopUrl" to desktopUrl,
            "bearerToken" to bearerToken,
            "deviceName" to deviceName,
            "autoPair" to autoPair,
        )
    }

    private fun firstNonBlank(vararg values: String?): String? {
        return values.firstOrNull { !it.isNullOrBlank() }?.trim()
    }

    private fun isDebuggable(): Boolean {
        return (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    companion object {
        private const val EXTRA_PAIRING_PAYLOAD = "private_gallery_pairing_payload"
        private const val EXTRA_DESKTOP_URL = "private_gallery_desktop_url"
        private const val EXTRA_BEARER_TOKEN = "private_gallery_mobile_bearer_token"
        private const val EXTRA_DEVICE_NAME = "private_gallery_device_name"
        private const val EXTRA_AUTO_PAIR = "private_gallery_auto_pair"
    }
}
