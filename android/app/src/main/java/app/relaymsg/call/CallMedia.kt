package app.relaymsg.call

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.webrtc.VideoTrack

/**
 * The video tracks of the call in progress, and which screen is showing it.
 *
 * Process-wide rather than held by a ViewModel because a call outlives any one
 * screen: it can start in [IncomingCallActivity] over the lock screen and carry
 * on in `MainActivity`. It lives in the app module so `:core` never has to know
 * about `org.webrtc`.
 */
object CallMedia {

    private val _remoteVideo = MutableStateFlow<VideoTrack?>(null)

    /** The peer's camera, once their track arrives. */
    val remoteVideo: StateFlow<VideoTrack?> = _remoteVideo.asStateFlow()

    private val _localVideo = MutableStateFlow<VideoTrack?>(null)

    /** This device's camera, for the self-preview. */
    val localVideo: StateFlow<VideoTrack?> = _localVideo.asStateFlow()

    private val _fullScreen = MutableStateFlow(false)

    /**
     * True while [IncomingCallActivity] is on screen.
     *
     * `MainActivity` hides its own call overlay when this is set. Two live
     * renderers attached to one `VideoTrack` is not something to find out about
     * on a user's phone.
     */
    val fullScreen: StateFlow<Boolean> = _fullScreen.asStateFlow()

    fun setRemoteVideo(track: VideoTrack?) {
        _remoteVideo.value = track
    }

    fun setLocalVideo(track: VideoTrack?) {
        _localVideo.value = track
    }

    fun setFullScreen(active: Boolean) {
        _fullScreen.value = active
    }
}
