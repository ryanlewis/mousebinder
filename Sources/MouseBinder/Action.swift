import AppKit
import os

private let log = Logger(subsystem: "io.rlew.mousebinder", category: "action")

/// The actions a mouse button can be bound to. v1 ships a small list; the enum
/// is `Codable`/`CaseIterable` so adding more later is trivial.
enum BindableAction: String, CaseIterable, Identifiable, Codable {
    case missionControl
    case appExpose
    case launchpad
    case showDesktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appExpose:      return "App Exposé"
        case .launchpad:      return "Launchpad"
        case .showDesktop:    return "Show Desktop"
        }
    }

    /// The Dock notification that toggles this feature. These are the strings the
    /// Dock listens on internally; far more reliable than launching an `.app`
    /// (Launchpad.app no longer exists on macOS 26) or synthesising the default
    /// keyboard shortcut (which the user may have remapped or disabled).
    fileprivate var dockNotification: String {
        switch self {
        case .missionControl: return "com.apple.expose.awake"
        case .appExpose:      return "com.apple.expose.front.awake"
        case .launchpad:      return "com.apple.launchpad.toggle"
        case .showDesktop:    return "com.apple.showdesktop.awake"
        }
    }
}

/// Triggers an action by poking the Dock. `CoreDockSendNotification` is a private
/// but long-stable Dock entry point; it toggles the feature regardless of the
/// user's keyboard-shortcut config, and returns immediately (safe to call from
/// the event-tap path without risking the callback-timeout that disables the tap).
enum ActionRunner {
    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, Int) -> Void

    /// Resolved once. The symbol is already mapped into any AppKit process, so a
    /// plain `RTLD_DEFAULT` lookup finds it — no dlopen of a private framework.
    private static let coreDockSend: CoreDockSendNotificationFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "CoreDockSendNotification") else {
            log.error("CoreDockSendNotification not found")
            return nil
        }
        return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
    }()

    /// Returns false if the Dock entry point couldn't be resolved, so the caller
    /// can decline to swallow the click — a button that can't act keeps its native
    /// behaviour rather than going dead.
    @discardableResult
    static func run(_ action: BindableAction) -> Bool {
        guard let send = coreDockSend else { return false }
        send(action.dockNotification as CFString, 0)
        return true
    }
}
