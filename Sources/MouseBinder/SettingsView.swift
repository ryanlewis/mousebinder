import SwiftUI

/// The Settings window. Grouped `Form` styled after the Tuna preferences look.
/// One row per bindable action; each row carries its own bind/unbind control.
struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            if !state.permissionGranted {
                Section {
                    permissionRow
                }
            }

            Section {
                ForEach(BindableAction.allCases) { action in
                    LabeledContent(action.title) {
                        ActionRecorder(state: state, action: action)
                    }
                }
            } header: {
                Text("Button Binding")
            } footer: {
                if state.capturingAction != nil {
                    Text("Press a middle or side button. Click × to cancel.")
                } else if !state.isEnabled {
                    Text("MouseBinder is disabled — bindings won't fire until you turn it on below.")
                } else {
                    Text("Bind a middle or side button to each action. Reusing a button moves it.")
                }
            }

            Section {
                ForEach(state.ignoredApps) { app in
                    HStack(spacing: 8) {
                        appIcon(for: app)
                        Text(app.name)
                        Spacer()
                        ClearButton(help: "Remove from ignore list") {
                            state.removeIgnoredApp(app)
                        }
                    }
                }
                Button("Add App…") { state.addIgnoredApp() }
            } header: {
                Text("Ignore in These Apps")
            } footer: {
                Text("When one of these apps is focused, bound buttons pass through "
                     + "untouched (e.g. so a browser keeps its back/forward).")
            }

            Section {
                Toggle("Enabled", isOn: $state.isEnabled)
                Toggle("Open at Login", isOn: Binding(
                    get: { state.openAtLogin },
                    set: { state.setOpenAtLogin($0) }
                ))
            } footer: {
                if let error = state.loginItemError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 620)
        // Show a Dock icon only while this window is on screen.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private func appIcon(for app: IgnoredApp) -> some View {
        Image(nsImage: state.icon(for: app))
            .resizable()
            .frame(width: 18, height: 18)
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility permission needed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("MouseBinder needs Accessibility access to read and remap mouse buttons.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings…") { state.openAccessibilitySettings() }
                Button("Re-check") { state.recheckPermission() }
            }
        }
        .padding(.vertical, 2)
    }
}

/// The trailing control for one action row. Three states:
///  - capturing for this action: "Press a side button…" pill with × to cancel
///  - bound: a "Button N" pill with × to unbind
///  - unbound: a "Bind" button (disabled while another row is capturing)
struct ActionRecorder: View {
    @ObservedObject var state: AppState
    let action: BindableAction

    var body: some View {
        if state.capturingAction == action {
            pill {
                Text("Press a button…")
                    .foregroundStyle(.blue)
                ClearButton(help: "Unbind") { state.cancelCapture() }
            }
        } else if let button = state.button(for: action) {
            pill {
                Text("Button \(button)")
                    .monospacedDigit()
                ClearButton(help: "Unbind") { state.unbind(action) }
            }
        } else {
            Button("Bind") { state.startCapture(for: action) }
                .disabled(!state.permissionGranted || state.capturingAction != nil)
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.vertical, 4)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(.quaternary, in: Capsule())
    }
}

/// A plain × control used to clear a binding or remove an ignore-list row.
/// Extracted so the glyph/style lives in one place (it was duplicated across the
/// binding rows and the ignore list); pass `help` for the per-use tooltip.
struct ClearButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
