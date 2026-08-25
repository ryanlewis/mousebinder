import AppKit
import SwiftUI

/// The About window: app icon, tagline, version info, and a GitHub link.
/// Fixed-size, hidden title bar (the traffic lights float over the content).
struct AboutView: View {
    private static let repoURL = URL(string: "https://github.com/ryanlewis/mousebinder")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)

            Text("MouseBinder")
                .font(.title.bold())

            Text("Binds spare mouse buttons to Mission Control, App Exposé, Launchpad, or Show Desktop.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Version").gridColumnAlignment(.trailing)
                    Text(version).monospaced()
                }
                GridRow {
                    Text("Build")
                    Text(build).monospaced()
                }
            }
            .padding(.top, 8)

            Button("GitHub") { NSWorkspace.shared.open(Self.repoURL) }
                .padding(.top, 8)
        }
        .padding(.top, 36)   // room for the floating traffic lights
        .padding([.horizontal, .bottom], 28)
        .frame(width: 300)
        .onAppear { ActivationPolicy.windowAppeared() }
        .onDisappear { ActivationPolicy.windowClosed() }
    }
}

/// LSUIElement apps should show a Dock icon only while a window is on screen.
/// Each window flips the policy in onAppear/onDisappear; the close path re-checks
/// asynchronously (after the closing window is gone) and keeps the Dock icon when
/// another window — e.g. Settings behind About — is still open.
enum ActivationPolicy {
    static func windowAppeared() {
        NSApp.setActivationPolicy(.regular)
    }

    static func windowClosed() {
        DispatchQueue.main.async {
            let anyWindowVisible = NSApp.windows.contains {
                $0.isVisible && $0.styleMask.contains(.titled)
            }
            if !anyWindowVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
