package app.relaymsg.ui

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import java.io.File

/**
 * Records a voice note.
 *
 * AAC in an MP4 container at 32 kbit/s mono, which is what iOS records and what
 * keeps a minute of speech near 250 KB — an attachment goes through the whole
 * sealed blob pipeline, so size here is upload, download and storage for both
 * sides.
 *
 * Recording lands in the app's cache and is deleted as soon as the bytes are
 * read: the plaintext of a voice note should not outlive the send.
 */
class VoiceNoteRecorder(private val context: Context) {

    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var startedAt: Long = 0

    val isRecording: Boolean get() = recorder != null

    /** Elapsed milliseconds, for the timer next to the waveform. */
    val elapsedMs: Long get() = if (isRecording) System.currentTimeMillis() - startedAt else 0

    fun start(): Boolean {
        if (isRecording) return true
        val target = File(context.cacheDir, "voice-${System.currentTimeMillis()}.m4a")
        return runCatching {
            val created = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION") MediaRecorder()
            }
            created.apply {
                setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioChannels(1)
                setAudioSamplingRate(44_100)
                setAudioEncodingBitRate(32_000)
                setOutputFile(target.absolutePath)
                prepare()
                start()
            }
            recorder = created
            file = target
            startedAt = System.currentTimeMillis()
        }.isSuccess.also { if (!it) cleanUp() }
    }

    /**
     * Stops and returns the bytes, or null if nothing usable was captured.
     *
     * A recording shorter than a moment is almost always a mis-tap, and
     * MediaRecorder can produce an unplayable file from one.
     */
    fun finish(): ByteArray? {
        val target = file
        val duration = elapsedMs
        stopRecorder()
        if (target == null || duration < MIN_MS) {
            target?.delete()
            file = null
            return null
        }
        val bytes = runCatching { target.readBytes() }.getOrNull()
        target.delete()
        file = null
        return bytes
    }

    fun cancel() {
        stopRecorder()
        file?.delete()
        file = null
    }

    private fun stopRecorder() {
        val active = recorder ?: return
        // stop() throws when nothing was captured; the file is dropped either
        // way, so the failure is not worth propagating.
        runCatching { active.stop() }
        runCatching { active.release() }
        recorder = null
    }

    private fun cleanUp() {
        stopRecorder()
        file?.delete()
        file = null
    }

    private companion object {
        const val MIN_MS = 600L
    }
}
