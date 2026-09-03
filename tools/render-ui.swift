// Renders Drift's SwiftUI views offscreen to PNGs.
//
// Compiled against the app's own view sources (everything in Sources/DriftApp except
// DriftAppMain.swift, which owns @main), so this exercises the real PopoverView,
// SettingsView and DriftScreenView layouts. It catches crashes and layout breakage in
// view bodies without needing Screen Recording permission or a human clicking the
// menu bar. See tools/render-ui.sh.
import AppKit
import SwiftUI

private let outDir: String = {
    let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/ui"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}()

/// Backstop against a view laying out to nothing at all.
///
/// Be clear about what this does NOT catch. A container with no intrinsic height — a bare
/// `ScrollView`, say — collapses inside a real popover, which sizes itself to fit its
/// content. That cannot be reproduced here: an `NSHostingView` in an offscreen window
/// reports the same `fittingSize` either way, because this harness does not go through the
/// popover's sizing path. So this guard only catches a total collapse, and popover layout
/// still has to be looked at in the running app.
private let minimumBelievableHeight: CGFloat = 120

@MainActor
func render<V: View>(
    _ view: V,
    named name: String,
    size: CGSize,
    appearance: NSAppearance.Name = .aqua,
    // When true, the view is laid out at its natural height rather than a forced one, the
    // way a popover would size it.
    sizeToFit: Bool = false
) {
    let hosting = NSHostingView(rootView: view)

    // The hosting view is put in a real (but far-offscreen) window on purpose. AppKit
    // control text — TextField placeholders, button titles, Picker labels — is only
    // drawn once the view has a window and a backing store, so capturing a window-less
    // hosting view yields the layout with every label missing.
    // A deliberately short starting height when sizing to fit, so the content's own ideal
    // height is what ends up being measured.
    let startSize = sizeToFit ? CGSize(width: size.width, height: 1) : size
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: startSize),
        styleMask: [.borderless], backing: .buffered, defer: false
    )
    // Without an explicit appearance the offscreen window resolves .primary to
    // dark-mode white, which renders every label invisible against a light background.
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
    window.orderFront(nil)

    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))

    // Grow the window to whatever the content actually wants, so nothing is clipped.
    let fitting = hosting.fittingSize
    if fitting.height > startSize.height {
        window.setContentSize(NSSize(width: size.width, height: fitting.height))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    window.display()

    if sizeToFit, fitting.height < minimumBelievableHeight {
        print("FAIL \(name): laid out only \(Int(fitting.height))pt tall — a container with no intrinsic height has collapsed")
        exit(1)
    }

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("FAIL \(name): no bitmap rep"); exit(1)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("FAIL \(name): no png"); exit(1)
    }
    let path = "\(outDir)/\(name).png"
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("FAIL \(name): \(error)"); exit(1) }
    print("OK   \(path)  (\(rep.pixelsWide)x\(rep.pixelsHigh), fitting \(Int(fitting.width))x\(Int(fitting.height)))")

    // Also render through SwiftUI's own rasteriser. cacheDisplay goes through AppKit's
    // drawing path, which captures shapes and emoji but drops SwiftUI-drawn text in
    // control-heavy views; ImageRenderer walks the SwiftUI tree instead and gets the
    // labels. Neither one alone shows the whole picture, so both are written out.
    // Sized the same way as the AppKit pass above, or a GeometryReader-based view (the
    // Drift screen) collapses to nothing here.
    let sized = sizeToFit
        ? AnyView(view.frame(width: size.width))
        : AnyView(view.frame(width: size.width, height: size.height))
    let renderer = ImageRenderer(content: sized)
    renderer.scale = 2
    if let image = renderer.nsImage,
       let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        let swiftUIPath = "\(outDir)/\(name)-swiftui.png"
        try? png.write(to: URL(fileURLWithPath: swiftUIPath))
        print("OK   \(swiftUIPath)  (ImageRenderer)")
    }

    window.orderOut(nil)
    window.contentView = nil
}

@main
struct RenderUI {
    @MainActor
    static func main() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    // A scratch store so this never touches the real app's settings or published status.
    let id = "co.drift.render.\(Int(Date().timeIntervalSince1970))"
    let defaults = UserDefaults(suiteName: id)!
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(id).appendingPathComponent("status.json")
    let store = StatusStore(defaults: defaults, sharedFile: SharedStatusFile(url: tmp))
    let controller = DriftController(existingStore: store)

    func popover() -> some View {
        PopoverView(controller: controller, store: store, dismiss: {})
    }

    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {

        // 1. Nothing picked yet — Start Drift must be disabled.
        render(popover(), named: "popover-empty-\(suffix)",
               size: CGSize(width: 340, height: 600), appearance: appearance, sizeToFit: true)

        // 2. The remembered case: a preset and a duration already selected.
        store.remember(status: .preset("lunch"))
        store.remember(duration: .minutes(30))
        render(popover(), named: "popover-selected-\(suffix)",
               size: CGSize(width: 340, height: 600), appearance: appearance, sizeToFit: true)

        // 3. A custom message, with the field revealed.
        store.remember(status: .custom("Waiting for the plumber"))
        render(popover(), named: "popover-custom-message-\(suffix)",
               size: CGSize(width: 340, height: 600), appearance: appearance, sizeToFit: true)

        // 4. A picked return time, with the time picker revealed.
        store.remember(duration: .clock(hour: 15, minute: 30))
        render(popover(), named: "popover-custom-time-\(suffix)",
               size: CGSize(width: 340, height: 600), appearance: appearance, sizeToFit: true)
        store.remember(status: .preset("lunch"))
        store.remember(duration: .minutes(30))

        // 5. Drift running.
        store.start(status: .preset("lunch"), duration: .minutes(30))
        render(popover(), named: "popover-active-\(suffix)",
               size: CGSize(width: 340, height: 600), appearance: appearance, sizeToFit: true)

        // 6. Drift running past its return time — no outdated time on screen.
        store.start(status: .preset("lunch"), duration: .minutes(5),
                    now: Date().addingTimeInterval(-3600))
        render(popover(), named: "popover-overdue-\(suffix)",
               size: CGSize(width: 340, height: 600), appearance: appearance, sizeToFit: true)
        store.end()

        render(SettingsView(controller: controller).environmentObject(store),
               named: "settings-\(suffix)", size: CGSize(width: 380, height: 420),
               appearance: appearance, sizeToFit: true)
    }

    // The screen itself, at a few realistic sizes and content lengths.
    let now = Date()
    let backAt = now.addingTimeInterval(35 * 60)
    let lunch = DisplayStatus(text: "Out for lunch", returnTime: backAt, updatedAt: now)

    render(DriftScreenView(display: lunch, phase: 0, now: now),
           named: "screen-laptop-at-rest-frame-0", size: CGSize(width: 1440, height: 900))
    // Three points through the swing, to see the tilt without a video.
    for (label, phase) in [("swing-left", 1.3), ("swing-right", 2.6), ("settling", 6.0), ("settled", 30.0)] {
        render(DriftScreenView(display: lunch, phase: phase, now: now),
               named: "screen-laptop-\(label)", size: CGSize(width: 1440, height: 900))
    }
    render(DriftScreenView(display: lunch, phase: 30, now: now),
           named: "screen-5k", size: CGSize(width: 2560, height: 1440))
    render(DriftScreenView(display: lunch, phase: 30, now: now),
           named: "screen-portrait", size: CGSize(width: 800, height: 1200))
    render(DriftScreenView(display: lunch, phase: 30, now: now),
           named: "screen-preview-thumbnail", size: CGSize(width: 480, height: 300))
    render(DriftScreenView(
                display: DisplayStatus(
                    text: "Waiting for the plumber to turn up, back after that",
                    returnTime: backAt, updatedAt: now),
                phase: 30, now: now),
           named: "screen-longtext", size: CGSize(width: 1440, height: 900))
    render(DriftScreenView(
                display: DisplayStatus(text: "In a meeting", returnTime: nil, updatedAt: now),
                phase: 30, now: now),
           named: "screen-no-return-time", size: CGSize(width: 1440, height: 900))
    render(DriftScreenView(
                display: DisplayStatus(text: "Out for lunch",
                                       returnTime: now.addingTimeInterval(-1800), updatedAt: now),
                phase: 30, now: now),
           named: "screen-overdue", size: CGSize(width: 1440, height: 900))
    render(DriftScreenView(
                display: DisplayStatus(text: DriftSettings.idleText, updatedAt: now),
                phase: 30, now: now),
           named: "screen-idle", size: CGSize(width: 1440, height: 900))

    defaults.removePersistentDomain(forName: id)
    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    print("ALL RENDERS OK")
    }
}
