import AppKit
import SwiftUI

@main
struct MouseBinderApp: App {
    @StateObject private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Default (.menu) style => a native NSMenu: items render as real menu rows.
        MenuBarExtra("MouseBinder", systemImage: "computermouse.fill") {
            MenuContent(state: state)
        }

        // A normal Window (rather than the Settings scene) so an LSUIElement app
        // can reliably bring it to front via openWindow + NSApp.activate.
        // Suppressed at launch so the app stays a menu-bar accessory until the
        // user opens Settings, which flips it to a regular, Dock-visible app.
        Window("MouseBinder Settings", id: "settings") {
            SettingsView(state: state)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Window("About MouseBinder", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        // Replace the standard about panel in the app menu (visible whenever a
        // window has made the app regular) so both routes open this window.
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MouseBinder") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "about")
                }
            }
        }
    }
}

/// Native menu-bar menu. Plain `Text` renders as a disabled header row; `Toggle`
/// becomes a checkmarked item; `Button`s become standard menu items. All binding
/// configuration lives in the Settings window.
struct MenuContent: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !state.permissionGranted {
            Button("⚠ Grant Accessibility…") { state.openAccessibilitySettings() }
        } else if state.bindings.isEmpty {
            Text("No bindings set")
        } else {
            ForEach(BindableAction.allCases) { action in
                if let button = state.button(for: action) {
                    Text("Button \(button) → \(action.title)")
                }
            }
        }

        Divider()

        Toggle("Enabled", isOn: $state.isEnabled)

        Button("Settings…") { open("settings") }
            .keyboardShortcut(",", modifiers: .command)

        Button("About MouseBinder") { open("about") }

        Divider()

        Button("Quit MouseBinder") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }

    private func open(_ id: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
