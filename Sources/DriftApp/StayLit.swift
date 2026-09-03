import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while Drift is showing your status.
///
/// This exists because of a mismatch nobody would guess at: this Mac turns its display off
/// after five minutes, and the screensaver needs a lit screen to be seen on. Start Drift
/// and walk away, and your sign is readable for five minutes and then it is a black panel —
/// which is exactly what "it works sometimes" looks like from across a room.
///
/// What this does *not* do is worth being precise about, because it sits next to the lock:
///
///  - it does not delay or prevent the Mac locking. The lock is already decided by then —
///    macOS asks for a password a fixed time after the screensaver starts, and that clock
///    is not affected by this;
///  - it holds `PreventUserIdleDisplaySleep`, the same assertion a video player holds. It
///    is a request not to go *idle*, not a power to stay awake: closing the lid, pressing
///    the power button or a `pmset sleepnow` all still sleep the Mac immediately;
///  - it is released the moment the session ends, and on quit.
///
/// The cost is honest: while you are away with Drift up, the screen stays lit and a laptop
/// on battery pays for it. That is the deal an away sign makes — a sign nobody can read is
/// not worth the battery it saves.
@MainActor
final class StayLit {

    private var assertion: IOPMAssertionID = IOPMAssertionID(0)
    private var isHeld = false

    private static let reason = "Drift is showing your away status" as CFString

    func hold() {
        guard !isHeld else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            StayLit.reason,
            &id
        )
        guard result == kIOReturnSuccess else {
            // Nothing to do about it, and nothing worth interrupting the user over: the
            // status still shows, it just goes dark when the display does.
            EventLog.append("display assertion failed (\(result))")
            return
        }
        assertion = id
        isHeld = true
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(0)
        isHeld = false
    }
}
