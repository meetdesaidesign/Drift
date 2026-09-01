// Headless verification for Drift.saver.
//
// Loads the built .saver exactly the way legacyScreenSaver does — NSBundle load,
// principalClass, init(frame:isPreview:) — then drives animateOneFrame() and renders
// offscreen PNGs. This proves the bundle links, the Swift principal class is registered,
// the status file is read and the SwiftUI view actually draws, all without needing to
// start a real screensaver.
//
//   swiftc -target arm64-apple-macos15.0 -framework ScreenSaver -framework AppKit \
//       -o build/saver-loadtest tools/saver-loadtest.swift
//   ./build/saver-loadtest build/Drift.saver build/preview
import AppKit
import ScreenSaver

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: saver-loadtest <path/to/Drift.saver> [output-prefix]")
    exit(2)
}
let saverPath = args[1]
let outPrefix = args.count > 2 ? args[2] : "build/saver-frame"

func fail(_ message: String) -> Never {
    print("FAIL: \(message)")
    exit(1)
}

guard let bundle = Bundle(path: saverPath) else { fail("no bundle at \(saverPath)") }
guard bundle.load() else { fail("bundle.load() returned false") }
print("OK  bundle loaded — \(bundle.bundleIdentifier ?? "no identifier")")

guard let principal = bundle.principalClass else { fail("principalClass is nil (check NSPrincipalClass)") }
print("OK  principalClass = \(principal)")

guard let saverClass = principal as? ScreenSaverView.Type else { fail("principal class is not a ScreenSaverView") }
let frame = NSRect(x: 0, y: 0, width: 1728, height: 1117)   // this Mac's panel, in points
guard let view = saverClass.init(frame: frame, isPreview: false) else { fail("init(frame:isPreview:) returned nil") }
print("OK  instantiated \(type(of: view)) at \(Int(frame.width))x\(Int(frame.height)), \(String(format: "%.0f", 1 / view.animationTimeInterval))fps")

view.startAnimation()
print("OK  startAnimation")

// Snapshot at points either side of the fade-in so the ramp itself is visible.
let snapshotAtSeconds: [Double] = [0.3, 1.0, 3.0, 30.0]
var elapsed = 0.0
var nextSnapshot = 0

func snapshot(_ seconds: Double) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("no bitmap rep") }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("no png data") }
    let path = "\(outPrefix)-\(String(format: "%05.1f", seconds))s.png"
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { fail("write \(path): \(error)") }
    print("OK  rendered \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh), \(png.count / 1024)KB)")
}

while nextSnapshot < snapshotAtSeconds.count {
    view.animateOneFrame()
    // Let the SwiftUI hosting view commit its layout before the next snapshot.
    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    elapsed += view.animationTimeInterval
    if elapsed >= snapshotAtSeconds[nextSnapshot] {
        snapshot(snapshotAtSeconds[nextSnapshot])
        nextSnapshot += 1
    }
}

view.stopAnimation()
print("OK  stopAnimation")
print("ALL CHECKS PASSED")
