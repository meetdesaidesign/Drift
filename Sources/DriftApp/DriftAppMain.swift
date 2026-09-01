import AppKit
import SwiftUI

@main
struct DriftAppMain: App {

    @StateObject private var controller = DriftController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
                .environmentObject(controller.store)
        } label: {
            MenuBarLabel(display: controller.store.currentDisplay)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar icon shows the current emoji when there is one, so a glance at the bar
/// tells you what Drift would display.
private struct MenuBarLabel: View {
    let display: DisplayStatus

    var body: some View {
        if display.emoji.isEmpty {
            Image(systemName: "moon.stars")
        } else {
            Text(display.emoji)
        }
    }
}
