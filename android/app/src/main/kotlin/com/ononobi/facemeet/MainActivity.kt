package com.ononobi.facemeet

import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.android.installreferrer.api.InstallReferrerClient.InstallReferrerResponse
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val installReferrerChannel = "com.ononobi.facemeet/install_referrer"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            installReferrerChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstallReferrer" -> readInstallReferrer(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun readInstallReferrer(result: MethodChannel.Result) {
        val referrerClient = InstallReferrerClient.newBuilder(this).build()
        var didReply = false

        fun reply(value: String?) {
            if (didReply) return
            didReply = true
            result.success(value)
            referrerClient.endConnection()
        }

        referrerClient.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                val referrer = try {
                    if (responseCode == InstallReferrerResponse.OK) {
                        referrerClient.installReferrer.installReferrer
                    } else {
                        null
                    }
                } catch (error: Exception) {
                    null
                }
                reply(referrer)
            }

            override fun onInstallReferrerServiceDisconnected() {
                reply(null)
            }
        })
    }
}
