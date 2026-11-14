package dev.axel.learnmath

import android.os.Build
import android.os.Bundle
import android.view.Display
import com.ryanheise.audioservice.AudioServiceActivity

// just_audio_background needs the activity to be an AudioServiceActivity.
class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        preferHighRefreshRate()
    }

    /**
     * Asks for the display's fastest mode at the current resolution. Many
     * phones with a 90/120/144 Hz panel run an app at 60 Hz unless it asks.
     */
    private fun preferHighRefreshRate() {
        val display: Display? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display
            else @Suppress("DEPRECATION") windowManager.defaultDisplay
        val current = display?.mode ?: return
        val best = display.supportedModes
            .filter {
                it.physicalWidth == current.physicalWidth &&
                    it.physicalHeight == current.physicalHeight
            }
            .maxByOrNull { it.refreshRate } ?: return
        if (best.refreshRate <= current.refreshRate) return
        window.attributes = window.attributes.apply {
            preferredDisplayModeId = best.modeId
        }
    }
}
