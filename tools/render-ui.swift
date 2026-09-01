// Renders Drift's SwiftUI views offscreen to PNGs.
//
// Compiled against the app's own view sources (everything in Sources/DriftApp except
// DriftAppMain.swift, which owns @main), so this exercises the real MenuBarView,
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
/// Be clear about what this does NOT catch. A bare `ScrollView` inside a `MenuBarExtra`
/// popover collapses to zero height in the real app, because the popover sizes to fit and a
/// ScrollView has no intrinsic height — that bug shipped once. It cannot be reproduced
/// here: an `NSHostingView` in an offscreen window reports the *same* `fittingSize` with
/// and without the ScrollView (measured: 340x530 either way), because this harness does not
/// go through the popover's sizing path. So this guard only catches a total collapse, and
/// popover layout still has to be looked at in the running app.
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
    let renderer = ImageRenderer(content: view.frame(width: size.width))
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

    // A scratch store so this never touches the real app's settings or your calendar.
    let id = "co.drift.render.\(Int(Date().timeIntervalSince1970))"
    let defaults = UserDefaults(suiteName: id)!
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(id).appendingPathComponent("status.json")
    let store = StatusStore(
        defaults: defaults,
        sharedFile: SharedStatusFile(url: tmp),
        fetchEvents: {
            [CalendarEvent(title: "Design review",
                           start: Date().addingTimeInterval(-600),
                           end: Date().addingTimeInterval(1800))]
        }
    )
    store.updateCustomStatus(
        text: "Out for lunch",
        emoji: "🍜",
        returnTime: Calendar.current.date(bySettingHour: 14, minute: 30, second: 0, of: Date())
    )
    let controller = DriftController(existingStore: store)

    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        render(MenuBarView(controller: controller).environmentObject(store),
               named: "menubar-custom-\(suffix)", size: CGSize(width: 340, height: 700),
               appearance: appearance, sizeToFit: true)

        store.setSource(.calendar)
        render(MenuBarView(controller: controller).environmentObject(store),
               named: "menubar-calendar-\(suffix)", size: CGSize(width: 340, height: 700),
               appearance: appearance, sizeToFit: true)
        store.setSource(.custom)

        render(SettingsView(controller: controller).environmentObject(store),
               named: "settings-general-\(suffix)", size: CGSize(width: 520, height: 800),
               appearance: appearance)

        // The Calendar pane, including the Accounts list. With no calendar access here it
        // shows its empty state, which is the path a new user sees first.
        render(SettingsView(controller: controller, initialTab: .calendar).environmentObject(store),
               named: "settings-calendar-\(suffix)", size: CGSize(width: 520, height: 800),
               appearance: appearance)
    }

    // The full-screen look at a few realistic sizes and content lengths.
    render(DriftScreenView(display: store.currentDisplay, phase: 4),
           named: "screen-laptop", size: CGSize(width: 1440, height: 900))
    render(DriftScreenView(display: DisplayStatus(
                emoji: "🗓️",
                text: "In a very long all-hands planning meeting about next quarter",
                subtitle: "Back around 4:15 PM"), phase: 4),
           named: "screen-longtext", size: CGSize(width: 1440, height: 900))
    render(DriftScreenView(display: DisplayStatus(text: "Away from desk"), phase: 4),
           named: "screen-fallback", size: CGSize(width: 1440, height: 900))
    render(DriftScreenView(display: store.currentDisplay, phase: 4),
           named: "screen-narrow", size: CGSize(width: 800, height: 1200))

    defaults.removePersistentDomain(forName: id)
    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
    print("ALL RENDERS OK")
    }
}
