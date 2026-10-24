package ca.cgagnier.wlednativeandroid.service.soundsync

/**
 * UDP Sound Sync V2 packet (44 bytes, packed, little-endian).
 *
 * Matches the `audioSyncPacket` struct from WLED audioreactive (WLED >= 0.14.0):
 * ```
 * struct __attribute__((packed)) audioSyncPacket {
 *   char    header[6];      // "00002"
 *   uint8_t gap1[2];        // padding, always 0
 *   float   sampleRaw;      // raw sample value (with AGC applied)
 *   float   sampleSmth;     // smoothed/averaged sample value
 *   uint8_t samplePeak;     // 0 = no peak, 1 = peak detected
 *   uint8_t frameCounter;   // incrementing counter (wraps at 256)
 *   uint8_t fftResult[16];  // 16 GEQ frequency channels, 0-255 each
 *   uint8_t gap2[2];        // padding, always 0
 *   float   FFT_Magnitude;  // amplitude of strongest frequency
 *   float   FFT_MajorPeak;  // strongest frequency in Hz
 * };
 * ```
 *
 * @see <a href="https://github.com/atuline/WLED/wiki/UDP-Sound-Sync">UDP Sound Sync Wiki</a>
 */
data class UdpSoundSyncPacket(
    val sampleRaw: Float = 0f,
    val sampleSmth: Float = 0f,
    val samplePeak: Boolean = false,
    val frameCounter: Int = 0,
    val fftResult: ByteArray = ByteArray(FFT_CHANNEL_COUNT),
    val fftMagnitude: Float = 0f,
    val fftMajorPeak: Float = 0f,
) {
    /**
     * Serializes this packet to a 44-byte little-endian binary array matching
     * the WLED V2 `audioSyncPacket` struct layout.
     */
    fun toByteArray(): ByteArray = ByteArray(PACKET_SIZE).apply {
        // Header: "00002\0" (6 bytes, null-terminated to match C char[6])
        val header = V2_HEADER.toByteArray(Charsets.US_ASCII)
        header.copyInto(this, destinationOffset = 0)
        this[5] = 0 // null terminator

        // gap1[2] at offset 6 — already zero from ByteArray initialization

        // sampleRaw (float, little-endian) at offset 8
        writeFloatLE(sampleRaw, offset = 8)

        // sampleSmth (float, little-endian) at offset 12
        writeFloatLE(sampleSmth, offset = 12)

        // samplePeak (uint8) at offset 16
        this[16] = if (samplePeak) 1 else 0

        // frameCounter (uint8, wraps at 256) at offset 17
        this[17] = (frameCounter and 0xFF).toByte()

        // fftResult[16] at offset 18
        fftResult.copyInto(this, destinationOffset = 18)

        // gap2[2] at offset 34 — already zero

        // FFT_Magnitude (float, little-endian) at offset 36
        writeFloatLE(fftMagnitude, offset = 36)

        // FFT_MajorPeak (float, little-endian) at offset 40
        writeFloatLE(fftMajorPeak, offset = 40)
    }

    private fun ByteArray.writeFloatLE(value: Float, offset: Int) {
        val bits = value.toBits()
        this[offset] = (bits and 0xFF).toByte()
        this[offset + 1] = ((bits shr 8) and 0xFF).toByte()
        this[offset + 2] = ((bits shr 16) and 0xFF).toByte()
        this[offset + 3] = ((bits shr 24) and 0xFF).toByte()
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is UdpSoundSyncPacket) return false
        return sampleRaw == other.sampleRaw &&
            sampleSmth == other.sampleSmth &&
            samplePeak == other.samplePeak &&
            frameCounter == other.frameCounter &&
            fftResult.contentEquals(other.fftResult) &&
            fftMagnitude == other.fftMagnitude &&
            fftMajorPeak == other.fftMajorPeak
    }

    override fun hashCode(): Int {
        var result = sampleRaw.hashCode()
        result = 31 * result + sampleSmth.hashCode()
        result = 31 * result + samplePeak.hashCode()
        result = 31 * result + frameCounter
        result = 31 * result + fftResult.contentHashCode()
        result = 31 * result + fftMagnitude.hashCode()
        result = 31 * result + fftMajorPeak.hashCode()
        return result
    }

    companion object {
        const val V2_HEADER = "00002"
        const val PACKET_SIZE = 44
        const val FFT_CHANNEL_COUNT = 16

        /** Default UDP multicast group for WLED sound sync. */
        const val DEFAULT_MULTICAST_ADDRESS = "239.0.0.1"

        /** Default UDP port for WLED sound sync. */
        const val DEFAULT_PORT = 11988

        /** Maximum packets per second (50 fps = one packet every 20ms). */
        const val MAX_PACKETS_PER_SECOND = 50

        /** Interval between packets in milliseconds. */
        const val PACKET_INTERVAL_MS = 1000L / MAX_PACKETS_PER_SECOND
    }
}
