import AppKit
import Combine
import SwiftUI

/// The status item and its popover.
///
/// Owned directly rather than through `MenuBarExtra` because Drift has to close the
/// popover itself: pressing Start Drift closes it, and so does Escape.
@MainActor
final class MenuBarController: NSObject {

    private let controller: DriftController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    init(controller: DriftController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Drift")
        }
        updateIcon(active: controller.store.isActive)

        // The icon is the only part of the UI that is visible with the popover closed,
        // so it is the only part that needs watching from here.
        controller.store.$session
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] active in self?.updateIcon(active: active) }
            .store(in: &cancellables)
    }

    /// A filled moon while a session is running, a hollow one when not. Enough to catch
    /// your eye if you glance up; not enough to be a badge.
    private func updateIcon(active: Bool) {
        guard let button = statusItem.button else { return }
        let name = active ? "moon.stars.fill" : "moon.stars"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: active ? "Drift is active" : "Drift")
        image?.isTemplate = true
        button.image = image
        button.toolTip = active ? "Drift is showing your status" : "Drift"
    }

    // MARK: Showing

    @objc private func togglePopover() {
        popover.isShown ? close() : show()
    }

    private func show() {
        guard let button = statusItem.button else { return }

        // Rebuilt on every open so the popover always starts from the stored choices and
        // sizes itself to whichever half — setup or active — it is about to show.
        let hosting = PopoverHostingController(
            rootView: PopoverView(
                controller: controller,
                store: controller.store,
                dismiss: { [weak self] in self?.close() }
            )
        )
        hosting.sizingOptions = [.preferredContentSize]
        hosting.onCancel = { [weak self] in self?.close() }
        popover.contentViewController = hosting

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the popover draws but never takes the keyboard, so Return and
        // Escape go nowhere and Tab cannot reach the buttons.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func close() {
        popover.performClose(nil)
    }
}

/// Hosts the popover's SwiftUI content and turns Escape into a close.
///
/// Escape arrives as `cancelOperation(_:)` on the responder chain, which SwiftUI does not
/// surface, so it is caught here.
private final class PopoverHostingController<Content: View>: NSHostingController<Content> {

    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
