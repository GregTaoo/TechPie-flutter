package club.geekpie.techpie

import android.app.Activity
import android.content.Context
import android.content.pm.ApplicationInfo
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** The sound and vibration for one event share one native start point. */
class EcardFeedback(activity: Activity, messenger: BinaryMessenger) {
    private val context = activity.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "techpie/feedback")
    private val pool = SoundPool.Builder().setMaxStreams(1).setAudioAttributes(
        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
    ).build()
    private val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
        context.getSystemService(VibratorManager::class.java)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        (context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)
    }
    private val patterns = mutableMapOf<String, Pattern>()
    private val ready = mutableSetOf<Int>()
    private val failed = mutableSetOf<Int>()
    private var pending: Request? = null
    private var stream = 0
    private var generation = 0
    private var disposed = false

    init {
        activity.volumeControlStream = AudioManager.STREAM_MUSIC
        pool.setOnLoadCompleteListener { _, sample, status ->
            handler.post {
                if (!disposed) {
                    if (status == 0) ready.add(sample) else failed.add(sample)
                    pending?.takeIf { it.pattern.sample == sample }?.let {
                        pending = null
                        start(it)
                    }
                }
            }
        }
        runCatching {
            val json = JSONObject(context.assets.open(assetKey("assets/campus_card/data/feedback_patterns.json"))
                .bufferedReader().use { it.readText() })
            for (event in json.keys()) {
                val raw = json.getJSONObject(event)
                val pulses = raw.getJSONArray("pulses")
                val sample = context.assets.openFd(assetKey(raw.getString("audio"))).use { pool.load(it, 1) }
                patterns[event] = Pattern(sample, raw.getLong("durationMs"), (0 until pulses.length()).map { index ->
                    val pulse = pulses.getJSONObject(index)
                    Pulse(pulse.getLong("atMs"), pulse.getLong("durationMs"), pulse.getDouble("intensity").toFloat())
                })
            }
        }
        channel.setMethodCallHandler { call, result ->
            if (call.method != "play") {
                result.notImplemented()
            } else {
                val event = call.argument<String>("event")
                val pattern = patterns[event]
                if (disposed || pattern == null) {
                    result.error("feedback_unavailable", "Feedback assets are unavailable.", null)
                } else {
                    pending?.result?.success(null)
                    pending = null
                    generation++
                    stopPlayback()
                    val request = Request(event!!, pattern, call.argument<Boolean>("sound") == true,
                        call.argument<Boolean>("vibration") == true, result)
                    if (request.sound && pattern.sample !in ready && pattern.sample !in failed && pattern.sample != 0) {
                        pending = request
                    } else {
                        start(request)
                    }
                }
            }
        }
    }

    private fun assetKey(path: String) = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(path)

    private fun start(request: Request) {
        if (request.sound) {
            if (request.pattern.sample == 0 || request.pattern.sample in failed) {
                request.result.error("feedback_audio_failed", "The sound could not be loaded.", null)
                return
            }
            stream = pool.play(request.pattern.sample, 1f, 1f, 1, 0, 1f)
            if (stream == 0) {
                request.result.error("feedback_audio_failed", "The sound could not be started.", null)
                return
            }
        }
        if (request.vibration && vibrator?.hasVibrator() == true) {
            vibrate(request.pattern)
        }
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            Log.d("TechPieFeedback", "play ${request.event} sound=${request.sound} vibration=${request.vibration}")
        }
        val current = generation
        handler.postDelayed({ if (generation == current) stopPlayback() }, request.pattern.durationMs)
        request.result.success(null)
    }

    @Suppress("DEPRECATION")
    private fun vibrate(pattern: Pattern) {
        val motor = vibrator ?: return
        val timings = mutableListOf<Long>()
        val amplitudes = mutableListOf<Int>()
        var cursor = 0L
        for (pulse in pattern.pulses) {
            timings.add((pulse.atMs - cursor).coerceAtLeast(0))
            amplitudes.add(0)
            timings.add(pulse.durationMs)
            amplitudes.add((pulse.intensity * 255).toInt().coerceIn(1, 255))
            cursor = pulse.atMs + pulse.durationMs
        }
        if (Build.VERSION.SDK_INT >= 26) {
            val levels = amplitudes.map { if (it == 0 || motor.hasAmplitudeControl()) it else VibrationEffect.DEFAULT_AMPLITUDE }.toIntArray()
            motor.vibrate(VibrationEffect.createWaveform(timings.toLongArray(), levels, -1))
        } else {
            motor.vibrate(timings.toLongArray(), -1)
        }
    }

    private fun stopPlayback() {
        if (stream != 0) pool.stop(stream)
        stream = 0
        vibrator?.cancel()
    }

    fun dispose() {
        disposed = true
        generation++
        pending?.result?.success(null)
        pending = null
        handler.removeCallbacksAndMessages(null)
        stopPlayback()
        pool.setOnLoadCompleteListener(null)
        pool.release()
        channel.setMethodCallHandler(null)
    }

    private data class Pulse(val atMs: Long, val durationMs: Long, val intensity: Float)
    private data class Pattern(val sample: Int, val durationMs: Long, val pulses: List<Pulse>)
    private data class Request(val event: String, val pattern: Pattern, val sound: Boolean,
        val vibration: Boolean, val result: MethodChannel.Result)
}
