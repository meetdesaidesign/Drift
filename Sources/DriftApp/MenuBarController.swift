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
    let statusItem: NSStatusItem
    let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    /// Where to ask for the item on first run, in points from the right-hand edge of
    /// the menu bar.
    ///
    /// Without this, macOS hands a brand-new status item the leftmost free slot, which on
    /// a notched Mac is the gap immediately beside the notch — a long way from the cluster
    /// of icons you actually look at, and easy to conclude Drift never launched. This asks
    /// for a slot among the others instead. It is written once and never again: drag the
    /// icon anywhere and macOS remembers that instead.
    private static let firstRunPosition = 450.0
    /// The key macOS itself uses for the item's remembered position. `Item-0` is the
    /// autosave name AppKit assigns when none is set.
    private static let positionKey = "NSStatusItem Preferred Position Item-0"

    init(controller: DriftController) {
        self.controller = controller
        if UserDefaults.standard.object(forKey: MenuBarController.positionKey) == nil {
            UserDefaults.standard.set(
                MenuBarController.firstRunPosition, forKey: MenuBarController.positionKey
            )
        }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Drift")
        } else {
            log.error("status item has no button — nothing will appear in the menu bar")
        }
        updateIcon(active: controller.store.isActive)
        logStatusItem()

        // The icon is the only part of the UI that is visible with the popover closed,
        // so it is the only part that needs watching from here.
        controller.store.$session
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] active in self?.updateIcon(active: active) }
            .store(in: &cancellables)
    }

    /// What the status item ended up as. Worth logging: an item can be created
    /// successfully and still be invisible, if the menu bar has no room left for it.
    private func logStatusItem() {
        let visible = statusItem.isVisible
        let hasImage = statusItem.button?.image != nil
        let frame = statusItem.button?.window?.frame.debugDescription ?? "no window"
        log.log("status item: visible=\(visible, privacy: .public) image=\(hasImage, privacy: .public) window=\(frame, privacy: .public)")
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

    @objc func togglePopover() {
        log.log("menu bar item clicked (popover already shown: \(self.popover.isShown, privacy: .public))")
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
        log.log("popover shown: \(self.popover.isShown, privacy: .public)")
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
