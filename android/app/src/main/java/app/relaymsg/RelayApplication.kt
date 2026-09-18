package app.relaymsg

import android.app.Application

/**
 * Holds the single [app.relaymsg.core.RelayService] for the process.
 *
 * It lives here rather than in a ViewModel because the encrypted store, the
 * WebSocket and the Double Ratchet are process-wide, single-instance state —
 * opening a second store or a second socket would race on session state and
 * corrupt it.
 */
class RelayApplication : Application()
