import AppKit
import ApplicationServices
import Combine
import os
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private let log = Logger(subsystem: "io.rlew.mousebinder", category: "state")

/// The observable hub the UI binds to. Wires the event core's closures to
/// published state, owns the binding store, and handles capture + permissions.
///
/// Multi-binding with two invariants, both enforced in `finishCapture`:
///  - each action has at most one button,
///  - each button maps to at most one action.
/// So binding a button that's already used elsewhere *moves* it (clearing the
/// action that previously held it).
@MainActor
final class AppState: ObservableObject {
    @Published var bindings: [ButtonBinding]
    /// Apps in which bound buttons pass through (e.g. browsers keep back/forward).
    @Published var ignoredApps: [IgnoredApp]
    /// Which action we're currently capturing a button for (nil = idle).
    @Published var capturingAction: BindableAction?
    @Published var isEnabled: Bool { didSet { store.saveEnabled(isEnabled) } }
    @Published var permissionGranted = true
    @Published var openAtLogin = false
    /// Surfaced in the UI only if registering/unregistering the login item fails.
    @Published var loginItemError: String?

    private let store = BindingStore()
    private let tap = EventTapController()
    private var captureTimeout: Task<Void, Never>?
    /// App icons cached by bundle id so SwiftUI re-renders don't re-hit Launch
    /// Services + disk on every frame (see `icon(for:)`).
    private var iconCache: [String: NSImage] = [:]

    init() {
        isEnabled = store.loadEnabled()
        bindings = store.load()
        ignoredApps = store.loadIgnoredApps()
        openAtLogin = SMAppService.mainApp.status == .enabled
        wireTap()
        startTap()
        observeSystemEvents()
    }

    private func wireTap() {
        tap.isEnabled = { [weak self] in self?.isEnabled ?? false }
        tap.isCapturing = { [weak self] in self?.capturingAction != nil }
        tap.bindingFor = { [weak self] button in
            self?.bindings.first { $0.button == button }
        }
        tap.shouldIgnoreFrontmostApp = { [weak self] in
            guard let self, !self.ignoredApps.isEmpty,
                  let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            else { return false }
            return self.ignoredApps.contains { $0.bundleID == bundleID }
        }
        tap.onCapture = { [weak self] button in
            self?.finishCapture(button: button)
        }
        tap.onActionFired = { action in
            ActionRunner.run(action)
        }
        tap.onButtonSeen = { button in
            // Diagnostic only — visible via `log stream --debug`, off by default.
            log.debug("otherMouseDown button=\(button, privacy: .public)")
        }
    }

    // MARK: - Queries

    func button(for action: BindableAction) -> Int? {
        bindings.first { $0.action == action }?.button
    }

    // MARK: - Binding edits

    func unbind(_ action: BindableAction) {
        bindings.removeAll { $0.action == action }
        persist()
    }

    private func persist() {
        store.save(bindings)
    }

    // MARK: - Ignore list

    /// Pick an application bundle and add it to the ignore list. Uses an open
    /// panel so we capture the exact bundle id (more reliable than a typed name).
    func addIgnoredApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }

        guard !ignoredApps.contains(where: { $0.bundleID == bundleID }) else { return }
        let displayName = FileManager.default.displayName(atPath: url.path)
        // Strip only a trailing ".app", not every occurrence — a bundle whose name
        // legitimately contains ".app" should keep it.
        let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        ignoredApps.append(IgnoredApp(bundleID: bundleID, name: name))
        store.saveIgnoredApps(ignoredApps)
    }

    func removeIgnoredApp(_ app: IgnoredApp) {
        ignoredApps.removeAll { $0.bundleID == app.bundleID }
        store.saveIgnoredApps(ignoredApps)
    }

    /// Icon for an ignored app, loaded once and cached. Falls back to the generic
    /// application icon if the bundle can't be located.
    func icon(for app: IgnoredApp) -> NSImage {
        if let cached = iconCache[app.bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        iconCache[app.bundleID] = image
        return image
    }

    // MARK: - Capture (click-to-bind)

    func startCapture(for action: BindableAction) {
        guard permissionGranted else { return }
        capturingAction = action
        captureTimeout?.cancel()
        captureTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            // Only revert if *this* capture is still the one in flight. A cancelled
            // sleep still falls through to here, and a newer startCapture may have
            // replaced `capturingAction` — so compare the action rather than just
            // nil-checking, otherwise a stale timer aborts a fresh capture.
            guard let self, self.capturingAction == action else { return }
            self.capturingAction = nil  // silently revert; the UI returns to idle
        }
    }

    func cancelCapture() {
        captureTimeout?.cancel()
        capturingAction = nil
    }

    private func finishCapture(button: Int) {
        captureTimeout?.cancel()
        guard let action = capturingAction else { return }
        capturingAction = nil
        // Enforce both invariants: free the action's old button, and steal the
        // button from whatever action previously held it.
        bindings.removeAll { $0.action == action || $0.button == button }
        bindings.append(ButtonBinding(button: button, action: action))
        persist()
    }

    // MARK: - Permissions

    private func startTap() {
        permissionGranted = tap.start()
        if !permissionGranted { promptForAccessibility() }
    }

    /// The OS can tear down the session tap across sleep/wake or fast-user-switch
    /// without firing the disable callback, leaving every binding silently dead.
    /// Rebuild it on those transitions (a live tap makes this a no-op) and refresh
    /// the permission flag so the UI reflects reality.
    private func observeSystemEvents() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.permissionGranted = self?.tap.start() ?? false }
            }
        }
    }

    /// Re-check after the user grants permission in System Settings, then start.
    /// Mirrors `startTap()` so a still-denied re-check re-prompts instead of
    /// silently doing nothing.
    func recheckPermission() {
        startTap()
    }

    private func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Open at Login

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            openAtLogin = on
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
