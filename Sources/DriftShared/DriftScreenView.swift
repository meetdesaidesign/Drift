import SwiftUI

#if canImport(DriftCore)
import DriftCore
#endif

/// The Drift screen: a dark sign that says where you went.
///
/// Restrained on purpose. No gradient, no card, no illustration, nothing that moves in a
/// way you would notice — the whole job is to be legible from the other side of a room
/// and to look like it belongs on a Mac.
///
/// `phase` is the elapsed time in seconds and is supplied by the host rather than derived
/// from SwiftUI's animation engine, because inside `legacyScreenSaver` SwiftUI's implicit
/// animations cannot be relied on to tick.
///
/// Nothing here is allowed to *depend* on `phase` advancing. An earlier version faded the
/// text in over the first second, which meant a screen that had not yet been given an
/// animation frame rendered at zero opacity — indistinguishable from a broken
/// screensaver. `phase` now only moves the text a few points for burn-in, so the sign
/// reads correctly at `phase` 0 and would keep reading correctly if it never advanced
/// again. `tools/saver-loadtest.swift` checks exactly that.
public struct DriftScreenView: View {

    public var display: DisplayStatus
    public var phase: Double
    /// Passed in rather than read here so the return line can be rendered
    /// deterministically in tests and previews.
    public var now: Date

    public init(display: DisplayStatus, phase: Double, now: Date = Date()) {
        self.display = display
        self.phase = phase
        self.now = now
    }

    public static let background = Color(red: 0.0392, green: 0.0392, blue: 0.0392)   // #0A0A0A
    public static let primaryText = Color(red: 0.949, green: 0.949, blue: 0.941)     // #F2F2F0
    public static let secondaryText = Color(red: 0.549, green: 0.549, blue: 0.529)   // #8C8C87

    /// Burn-in insurance, and nothing more.
    ///
    /// The text wanders about 14pt over roughly seven minutes, which works out to a
    /// fifth of a point per second — far below what the eye reads as movement, and far
    /// enough that no pixel holds the same glyph for an afternoon.
    private var burnInOffset: CGSize {
        CGSize(
            width: 14 * sin(phase / 420.0),
            height: 10 * sin(phase / 610.0 + 1.7)
        )
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let statusSize = DriftScreenView.statusFontSize(for: size)
            let returnSize = DriftScreenView.returnFontSize(for: statusSize)
            let drift = burnInOffset

            ZStack {
                DriftScreenView.background

                VStack(alignment: .leading, spacing: statusSize * 0.42) {
                    Text(display.text)
                        .font(.system(size: statusSize, weight: .medium))
                        .foregroundStyle(DriftScreenView.primaryText)
                        .lineLimit(3)
                        // A long custom message wraps first, then shrinks — never clips.
                        .minimumScaleFactor(0.45)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let returnTime = display.returnTime {
                        Text(DriftFormat.backAround(returnTime, now: now))
                            .font(.system(size: returnSize, weight: .regular))
                            .foregroundStyle(DriftScreenView.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                // Left-aligned block, held to a share of the width so the left edge sits
                // in the same place whatever the status says.
                .frame(width: size.width * 0.62, alignment: .leading)
                // Slightly left of, and below, centre.
                .offset(
                    x: -size.width * 0.10 + drift.width,
                    y: size.height * 0.06 + drift.height
                )
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .background(DriftScreenView.background)
        .ignoresSafeArea()
    }

    // MARK: Type scale

    /// Scales off the shorter screen edge and then clamps, so the status lands in the
    /// 64–80pt range on any real display while still laying out sensibly in the
    /// thumbnail-sized preview System Settings draws.
    public static func statusFontSize(for size: CGSize) -> CGFloat {
        let minEdge = min(size.width, size.height)
        return min(max(minEdge * 0.085, 18), 80)
    }

    public static func returnFontSize(for statusSize: CGFloat) -> CGFloat {
        min(max(statusSize * 0.36, 11), 30)
    }
}
