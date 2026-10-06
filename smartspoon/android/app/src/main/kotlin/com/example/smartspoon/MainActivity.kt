package com.example.smartspoon

import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "smartspoon/system_settings"

    /**
     * ONE Flutter engine for the life of the process, not one per Activity.
     *
     * The spoon's Bluetooth link lives inside this engine: flutter_blue_plus
     * keeps its GATT connections per engine and calls disconnectAllDevices()
     * when that engine is torn down. With the default — engine owned by the
     * Activity — swiping the app out of Recents, or Android reclaiming the
     * Activity, destroyed the engine and dropped the spoon, while the
     * connectedDevice foreground service kept an empty process alive that
     * reconnected nothing.
     *
     * Held in FlutterEngineCache, the engine (and the ConnectionCoordinator
     * running in it) outlives the Activity for as long as the foreground
     * service keeps the process alive. Reopening the app reattaches to the
     * same running Dart state instead of cold-starting a new coordinator.
     *
     * The Dart entrypoint is NOT started here: the Activity delegate runs it on
     * the first attach, and skips it on later attaches because the engine is
     * already executing.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        return cache.get(ENGINE_ID)
            ?: FlutterEngine(context.applicationContext).also { cache.put(ENGINE_ID, it) }
    }

    /** See [provideFlutterEngine] — the process, not the Activity, owns the engine. */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Android exposes no API for an app to delete its own Bluetooth bond
        // (BluetoothDevice.removeBond is @hide). When the OS holds a stale bond
        // for a spoon, the ONLY fix is the user forgetting it in system
        // Bluetooth settings — so take them straight there instead of spelling
        // the path out in a paragraph of on-card text.
        //
        // applicationContext, not this Activity: the engine — and therefore
        // this handler — now outlives the Activity that registered it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val ctx = applicationContext
                when (call.method) {
                    "openBluetoothSettings" -> {
                        try {
                            ctx.startActivity(
                                Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            // Some OEM builds and work profiles do not expose a
                            // Bluetooth settings activity. Fall back to the
                            // top-level settings screen rather than throwing.
                            try {
                                ctx.startActivity(
                                    Intent(Settings.ACTION_SETTINGS)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private companion object {
        const val ENGINE_ID = "smartspoon_main_engine"
    }
}
