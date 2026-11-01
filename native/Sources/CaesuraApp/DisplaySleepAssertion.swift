import IOKit
import IOKit.pwr_mgt
import CaesuraCore

/// Holds a `NoDisplaySleepAssertion` while a break covers the screen.
///
/// Idle display sleep mid-break would end in the lock screen: a user who
/// waits a long break out without touching the machine comes back to the
/// login window instead of the desktop the break covered. While the
/// assertion is held, the display cannot idle-sleep and the idle screen
/// saver cannot start — the two paths macOS locks the screen through —
/// so nothing brings the lock screen up behind the break on its own.
/// A lock the user performs themselves (the lock shortcut, closing the lid)
/// is not affected; it stays with the suspend/lock handling.
///
/// This is the mechanism `caffeinate -d` uses (and a fullscreen video
/// playback holds the same assertion). The assertion is owned by the
/// process, so it dies with the process — even an unexpected quit cannot
/// leave the prevention behind. AppKit has no wrapper for it, hence IOKit.
final class DisplaySleepAssertion {
    private var assertionId: IOPMAssertionID?
    private let reason = "Caesura break is on the screen" as CFString

    func begin() {
        guard assertionId == nil else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )
        guard result == kIOReturnSuccess else {
            Log.warn("Caesura: could not hold the no-display-sleep assertion (\(result))")
            return
        }
        assertionId = id
        Log.info("Caesura: display sleep prevented while the break is on the screen "
                 + "(assertion \(id))")
    }

    func end() {
        guard let id = assertionId else { return }
        assertionId = nil
        let result = IOPMAssertionRelease(id)
        if result == kIOReturnSuccess {
            Log.info("Caesura: display sleep allowed again (assertion \(id) released)")
        } else {
            Log.warn("Caesura: could not release the no-display-sleep assertion (\(result))")
        }
    }
}
