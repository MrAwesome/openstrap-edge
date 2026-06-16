package wtf.openstrap.openstrap_edge

import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val edgeTrackingChannel = "openstrap/edge_tracking"
    private val deviceActionsChannel = "openstrap/device_actions"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, edgeTrackingChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, EdgeTrackingService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        stopService(Intent(this, EdgeTrackingService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Band-gesture actions. All no-risk OS APIs: media-key dispatch (works for any
        // player, no permission), system media volume, and a ringtone + vibrate.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceActionsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(
                        listOf(
                            "media_play_pause", "media_next", "media_prev",
                            "volume_up", "volume_down", "ring_phone", "torch"
                        )
                    )
                    "perform" -> result.success(perform(call.argument<String>("action") ?: ""))
                    else -> result.notImplemented()
                }
            }
    }

    private fun perform(action: String): Boolean {
        return try {
            when (action) {
                "media_play_pause" -> dispatchMediaKey(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
                "media_next" -> dispatchMediaKey(KeyEvent.KEYCODE_MEDIA_NEXT)
                "media_prev" -> dispatchMediaKey(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
                "volume_up" -> adjustVolume(AudioManager.ADJUST_RAISE)
                "volume_down" -> adjustVolume(AudioManager.ADJUST_LOWER)
                "ring_phone" -> ringPhone()
                "torch" -> toggleTorch()
                else -> return false
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun audio(): AudioManager =
        getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun dispatchMediaKey(keyCode: Int) {
        val am = audio()
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
    }

    private fun adjustVolume(direction: Int) {
        audio().adjustStreamVolume(
            AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI
        )
    }

    private fun ringPhone() {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        RingtoneManager.getRingtone(applicationContext, uri)?.play()
        vibrate()
    }

    // Torch via CameraManager.setTorchMode — no CAMERA permission required (API 23+).
    // We track the on/off state ourselves; if the system turns it off underneath us
    // the worst case is one tap that re-syncs the state.
    private var torchOn = false

    private fun toggleTorch() {
        val cm = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val camId = cm.cameraIdList.firstOrNull {
            cm.getCameraCharacteristics(it)
                .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return
        torchOn = !torchOn
        cm.setTorchMode(camId, torchOn)
    }

    @Suppress("DEPRECATION")
    private fun vibrate() {
        val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(500, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            vibrator.vibrate(500)
        }
    }
}
