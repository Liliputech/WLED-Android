package ca.cgagnier.wlednativeandroid.service.soundsync.audio

import android.media.audiofx.Visualizer
import co.touchlab.kermit.Logger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val TAG = "MusicAudioSource"
private val logger = Logger.withTag(TAG)

/**
 * Captures audio from the currently playing system audio using the
 * [Visualizer] API.
 *
 * The Visualizer API provides waveform data from the global audio output,
 * which we convert to normalized float samples. This works without special
 * permissions on most devices, though the API is deprecated since API 31.
 *
 * Note: The Visualizer waveform data is already decimated by the system,
 * so the effective sample rate is lower than the nominal capture rate.
 * We report the nominal rate but the DSP pipeline handles any rate.
 */
class MusicAudioSource(
    override val sampleRate: Int = DEFAULT_SAMPLE_RATE,
    private val captureRateMilliHz: Int = DEFAULT_SAMPLE_RATE * 1000,
    private val pollingIntervalMs: Long = 20L, // ~50fps
) : AudioSource {

    private val _isRunning = MutableStateFlow(false)
    override val isRunning: StateFlow<Boolean> = _isRunning.asStateFlow()

    private var visualizer: Visualizer? = null
    private var captureJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Synchronized
    override fun start(onAudioData: (FloatArray) -> Unit): Boolean {
        if (_isRunning.value) return true

        val viz = Visualizer(0) // 0 = global audio session
        viz.captureSize = Visualizer.getCaptureSizeRange()[1] // Max capture size

        val captureResult = viz.setDataCaptureListener(
            object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(
                    visualizer: Visualizer,
                    waveform: ByteArray,
                    samplingRate: Int,
                ) {
                    val samples = unsigned8ToFloat(waveform)
                    onAudioData(samples)
                }

                override fun onFftDataCapture(
                    visualizer: Visualizer,
                    fft: ByteArray,
                    samplingRate: Int,
                ) {
                    // FFT data is available but we compute our own FFT from waveform
                }
            },
            captureRateMilliHz, // Capture rate for listener callbacks
            true, // Waveform
            false, // FFT (we compute our own)
        )
        if (captureResult != Visualizer.SUCCESS) {
            logger.e { "Visualizer setDataCaptureListener failed: $captureResult" }
            viz.release()
            return false
        }

        val enableResult = viz.setEnabled(true)
        if (enableResult != Visualizer.SUCCESS) {
            logger.e { "Visualizer failed to enable: $enableResult" }
            viz.release()
            return false
        }

        visualizer = viz
        _isRunning.value = true

        // Visualizer uses its own callback thread, but we track state via a job
        // that keeps the scope alive while running
        captureJob = scope.launch {
            while (isActive && _isRunning.value) {
                delay(pollingIntervalMs * 10) // Just keep alive; actual data comes via callback
            }
        }

        return true
    }

    @Synchronized
    override fun stop() {
        _isRunning.value = false
        captureJob?.cancel()
        captureJob = null
        visualizer?.let { viz ->
            runCatching { viz.setEnabled(false) }
            runCatching { viz.release() }
        }
        visualizer = null
    }

    fun destroy() {
        stop()
        scope.cancel()
    }

    companion object {
        const val DEFAULT_SAMPLE_RATE = 44100
    }
}
