// The capture "shutter" feedback.
//
// Preferred source is the sound macOS itself plays for ⌘⇧3 / ⌘⇧4; if that
// system component path is gone (it is not a documented API and can move
// between releases) we fall back to a named system sound. Either way nothing is
// embedded in the bundle, so the app ships no audio file.

import AppKit

enum ShotSound {
    /// macOS's own screenshot sound, the same one ⌘⇧3 / ⌘⇧4 play. It lives in a
    /// system component rather than `/System/Library/Sounds`, so the path is not
    /// a documented API — hence the fallback instead of trusting it alone.
    static let systemCapturePath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport"
        + "/SystemSounds/system/Screen Capture.aif"

    /// Fallback: a short click from `/System/Library/Sounds`. `NSSound(named:)`
    /// also finds a same-named file in `~/Library/Sounds`, so it stays
    /// user-replaceable.
    static let fallbackName = "Tink"

    /// The first source that resolves. Resolved once; `NSSound` is a single-shot
    /// object and cheap to keep.
    static let sound: NSSound? =
        NSSound(contentsOfFile: systemCapturePath, byReference: true)
        ?? NSSound(named: NSSound.Name(fallbackName))

    /// Play the shutter, if the preference is on. A missing sound is a silent
    /// no-op: feedback must never block a capture.
    static func playIfEnabled() {
        guard Preferences.playSound else { return }
        play()
    }

    static func play() {
        guard let sound else { return }
        // `NSSound` is single-shot: `play()` fails while it is still playing, so
        // restart it for rapid captures.
        sound.stop()
        sound.play()
    }
}
