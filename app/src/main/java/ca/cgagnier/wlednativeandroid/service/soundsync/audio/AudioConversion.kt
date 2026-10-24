package ca.cgagnier.wlednativeandroid.service.soundsync.audio

/**
 * Converts 16-bit signed PCM samples to normalized floats in [-1.0, 1.0].
 */
fun pcm16ToFloat(pcm: ShortArray): FloatArray {
    if (pcm.isEmpty()) return FloatArray(0)
    val result = FloatArray(pcm.size)
    for (i in pcm.indices) {
        result[i] = pcm[i] / 32768.0f
    }
    return result
}

/**
 * Converts 16-bit signed PCM from a byte buffer (little-endian) to normalized floats.
 */
fun pcm16BytesToFloat(bytes: ByteArray, length: Int): FloatArray {
    val sampleCount = length / 2
    val result = FloatArray(sampleCount)
    for (i in 0 until sampleCount) {
        val lo = bytes[i * 2].toInt() and 0xFF
        val hi = bytes[i * 2 + 1].toInt() // Sign-extended
        val sample = (hi shl 8) or lo
        result[i] = sample / 32768.0f
    }
    return result
}

/**
 * Converts 8-bit unsigned PCM samples (0-255, centered at 128) to normalized
 * floats in [-1.0, 1.0]. Used for Android Visualizer waveform data.
 */
fun unsigned8ToFloat(bytes: ByteArray): FloatArray {
    if (bytes.isEmpty()) return FloatArray(0)
    val result = FloatArray(bytes.size)
    for (i in bytes.indices) {
        result[i] = ((bytes[i].toInt() and 0xFF) - 128) / 128.0f
    }
    return result
}
