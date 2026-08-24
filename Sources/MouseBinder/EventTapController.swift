import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "io.rlew.mousebinder", category: "eventtap")

/// Owns the `CGEventTap` on `.otherMouseDown`/`.otherMouseUp`. This is the whole
/// event core — the menu-bar app just hangs it off `AppState` and feeds it closures.
///
/// The tap is an *active* session tap (not listen-only) so it can swallow the
/// bound button by returning `nil`. The callback is a C function pointer, so we
/// hand `self` through `userInfo` and bounce back via `Unmanaged`.
///
/// Down and up must be swallowed as a *pair*: if only the down is eaten, the
/// matching up sails through to whatever is under the cursor — which, when the
/// action just opened Mission Control, is the Exposé overlay. An orphaned
/// button-up there can wedge WindowServer click tracking so left/right clicks
/// stop registering system-wide. `pendingSwallowedUps` records which buttons had
/// their down swallowed so the corresponding up is swallowed too.
///
/// Robustness (the bit the original design note missed): the OS will silently
/// disable the tap on `.tapDisabledByTimeout` / `.tapDisabledByUserInput` (and
/// across some wake/login transitions). The callback handles those and re-enables
/// the tap, otherwise the button just stops working with no signal.
final class EventTapController {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Buttons whose `.otherMouseDown` we swallowed and whose `.otherMouseUp` is
    /// therefore still owed a swallow. Only touched from the tap callback on the
    /// main run loop, so no locking needed.
    fileprivate var pendingSwallowedUps: Set<Int> = []

    // Hooks set by the owner. All are invoked synchronously on the main run loop
    // (the tap is attached there), so they may touch main-actor state directly.
    var isEnabled: () -> Bool = { true }
    var isCapturing: () -> Bool = { false }
    var bindingFor: (Int) -> ButtonBinding? = { _ in nil }
    /// True when the frontmost app is on the ignore list — bound buttons should
    /// pass through so the app's native behaviour (e.g. browser back/forward) wins.
    var shouldIgnoreFrontmostApp: () -> Bool = { false }
    var onCapture: (Int) -> Void = { _ in }
    var onActionFired: (BindableAction) -> Bool = { _ in false }
    /// Spike hook: fires for every `.otherMouseDown` so the first build doubles
    /// as the "what's my button number / does the tap see it" probe.
    var onButtonSeen: (Int) -> Void = { _ in }

    /// Returns false if the tap couldn't be created — almost always missing
    /// Accessibility permission. Caller should prompt and retry.
    @discardableResult
    func start() -> Bool {
        // A non-nil `eventTap` isn't proof of a working tap: when Accessibility
        // permission is revoked (or the OS tears the tap down across some
        // transitions) our reference is left dangling but the tap is dead. Treat a
        // disabled tap as dead and rebuild it, so a re-check can't report a corpse
        // as healthy and silently leave every binding inert.
        if let tap = eventTap {
            if CGEvent.tapIsEnabled(tap: tap) { return true }
            stop()
        }

        let mask: CGEventMask =
            1 << CGEventType.otherMouseDown.rawValue |
            1 << CGEventType.otherMouseUp.rawValue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,            // active tap — required to swallow
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            log.error("tapCreate failed — Accessibility permission likely not granted")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        // A pending swallow can't survive a tap rebuild: the up it was waiting for
        // may have been delivered while no tap was listening, and a stale entry
        // would eat the up of a later ordinary press of the same button.
        pendingSwallowedUps.removeAll()
        log.info("event tap started")
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap { CFMachPortInvalidate(tap) }
        eventTap = nil
        runLoopSource = nil
        pendingSwallowedUps.removeAll()
    }

    /// Revive a tap the OS auto-disabled.
    fileprivate func reenable() {
        guard let tap = eventTap else { return }
        log.notice("event tap was disabled by the system — re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Defensive: if this controller is ever torn down while its run-loop source
    /// is still installed, the C callback could fire against a freed `self`. Unwire
    /// the source on dealloc so that can't happen.
    deinit { stop() }
}

/// C-callback entry point. Runs on the main run loop. Keep it cheap — anything
/// slow here risks the timeout that disables the tap, so actions are dispatched
/// (`onActionFired` → `ActionRunner`, which is non-blocking) rather than run inline.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()

    // The OS told us the tap is going dead — bring it back.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller.reenable()
        return nil
    }

    let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))

    // Pair the swallow: an up whose down we ate must be eaten too, whatever mode
    // we're in now — otherwise it lands as an orphan in whatever the action just
    // opened (e.g. the Mission Control overlay) and can wedge click routing.
    if type == .otherMouseUp {
        if controller.pendingSwallowedUps.remove(button) != nil { return nil }
        return Unmanaged.passUnretained(event)
    }

    guard type == .otherMouseDown else { return Unmanaged.passUnretained(event) }

    controller.onButtonSeen(button)   // diagnostic

    // Capture mode: bind the next non-primary button (>= 2 — middle click or a
    // side button). Left/right (0/1) are separate event types that never reach
    // this tap, so normal clicking can't be hijacked mid-capture.
    if controller.isCapturing() {
        if button >= 2 {
            controller.onCapture(button)
            controller.pendingSwallowedUps.insert(button)
            return nil                // swallow the click we captured
        }
        return Unmanaged.passUnretained(event)
    }

    guard controller.isEnabled() else { return Unmanaged.passUnretained(event) }

    if let binding = controller.bindingFor(button) {
        // Let ignored apps keep the button's native behaviour: don't fire, don't swallow.
        if controller.shouldIgnoreFrontmostApp() {
            return Unmanaged.passUnretained(event)
        }
        // Only swallow the click if the action actually fired; otherwise pass it
        // through so a button that can't run its action keeps its native behaviour
        // instead of becoming a completely dead button.
        let fired = controller.onActionFired(binding.action)
        if binding.swallow && fired {
            controller.pendingSwallowedUps.insert(button)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    return Unmanaged.passUnretained(event)
}
