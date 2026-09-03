import AppKit
import SwiftUI

/// Everything Drift is willing to be configured about.
struct SettingsView: View {

    @ObservedObject var controller: DriftController
    @EnvironmentObject var store: StatusStore

    /// Read live rather than stored: Drift is ad-hoc signed, so launchd can lose the
    /// registration across a rebuild, and a remembered boolean would then lie.
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    /// macOS owns this, and it changes in System Settings rather than here, so it is
    /// re-read when the window appears rather than observed.
    @State private var installation = ScreenSaverInstallation.current()

    var body: some View {
        Form {
            Section {
                Toggle("Launch Drift at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Show return time on Drift screen", isOn: Binding(
                    get: { store.settings.showReturnTime },
                    set: { value in store.updateSettings { $0.showReturnTime = value } }
                ))
            }

            Section {
                Button("Open macOS Screen Saver Settings") {
                    controller.openScreenSaverSettings()
                }
                // Shown only when it is actually wrong. Drift cannot select its own
                // screensaver — that lives in a binary plist macOS owns — so if this is
                // unset, Start Drift shows someone else's screensaver.
                if !installation.isSelected {
                    Text(installation.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button("About Drift") { controller.showAbout() }
                Button("Quit Drift") { controller.quit() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            installation = ScreenSaverInstallation.current()
        }
    }
}
