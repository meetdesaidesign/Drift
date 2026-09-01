import SwiftUI

#if canImport(DriftCore)
import DriftCore
#endif

/// Drift's one and only full-screen look. Used by both the menu-bar app's full-screen
/// window and the .saver, so there is exactly one visual to maintain.
///
/// `phase` is the elapsed time in seconds and is supplied by the host rather than derived
/// from SwiftUI's animation engine. That is deliberate: inside `legacyScreenSaver`,
/// SwiftUI's implicit animations cannot be relied on to tick, whereas the saver's own
/// `animateOneFrame()` always does. The app drives `phase` from a `TimelineView`, the
/// saver drives it from its frame callback, and the view itself is identical in both.
public struct DriftScreenView: View {

    public var display: DisplayStatus
    public var phase: Double

    public init(display: DisplayStatus, phase: Double) {
        self.display = display
        self.phase = phase
    }

    // Deep charcoal, not pure black — pure black loses the glow entirely on OLED.
    private static let base = Color(red: 0.055, green: 0.059, blue: 0.070)

    /// Saturated but dim. Rendered additively over the charcoal, low-opacity saturated
    /// colour reads as coloured light; desaturated colour just reads as grey haze.
    private static let glows: [(colour: Color, strength: Double)] = [
        (Color(red: 0.24, green: 0.30, blue: 0.86), 0.42),   // deep indigo
        (Color(red: 0.04, green: 0.46, blue: 0.48), 0.34),   // cold teal
        (Color(red: 0.46, green: 0.16, blue: 0.52), 0.30),   // dim violet
    ]

    /// Ramps 0 → 1 over the first ~1.6s with an ease-out curve, so the screen fades up
    /// rather than snapping on.
    private var fadeIn: Double {
        let t = min(max((phase - 0.2) / 1.6, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let minEdge = min(size.width, size.height)

            ZStack {
                DriftScreenView.base

                // Additive glows, blended straight onto the base. No wrapper .opacity()
                // or .compositingGroup() here on purpose: either one would isolate the
                // layer into its own buffer, where .plusLighter has nothing to add to and
                // the colour collapses to grey. The fade-in is folded into the gradient
                // opacity instead.
                ForEach(Array(DriftScreenView.glows.enumerated()), id: \.offset) { index, glow in
                    glowLayer(index: index, colour: glow.colour, strength: glow.strength, in: size)
                }

                // Vignette: keeps the glow off the corners and pulls the eye to the centre.
                RadialGradient(
                    colors: [.clear, .clear, DriftScreenView.base.opacity(0.97)],
                    center: .center,
                    startRadius: minEdge * 0.10,
                    endRadius: minEdge * 0.95
                )

                content(minEdge: minEdge, width: size.width)
                    .opacity(fadeIn)
                    // The "drift": two out-of-phase sines, ±10pt, over roughly half a minute.
                    .offset(
                        x: 10 * sin(phase / 23.0),
                        y: 8 * cos(phase / 31.0)
                    )
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .background(DriftScreenView.base)
        .ignoresSafeArea()
    }

    // MARK: Ambient background

    private func glowLayer(index: Int, colour: Color, strength: Double, in size: CGSize) -> some View {
        let seed = Double(index)
        let minEdge = min(size.width, size.height)
        // Each glow orbits on its own slow, mutually-prime-ish period, so the background
        // as a whole never visibly loops.
        let periodX = 41.0 + seed * 13.0
        let periodY = 53.0 + seed * 11.0
        let radius = minEdge * (0.58 + 0.09 * seed)
        let driftX = size.width * 0.17 * sin(phase / periodX + seed * 2.1)
        let driftY = size.height * 0.14 * cos(phase / periodY + seed * 1.3)
        let anchorX = size.width * (0.34 + 0.16 * seed)
        let anchorY = size.height * (0.60 - 0.14 * seed)
        // A slow breath, so a status that never changes is never completely still.
        let breath = 1 + 0.05 * sin(phase / (19.0 + seed * 7.0))

        return RadialGradient(
            colors: [colour.opacity(strength * fadeIn), colour.opacity(strength * 0.35 * fadeIn), .clear],
            center: .center,
            startRadius: 0,
            endRadius: radius * breath
        )
        .frame(width: radius * 2.2, height: radius * 2.2)
        .position(x: anchorX + driftX, y: anchorY + driftY)
        .blendMode(.plusLighter)
    }

    // MARK: Foreground

    private func content(minEdge: CGFloat, width: CGFloat) -> some View {
        // Everything scales off the shorter screen edge, so the layout holds on a
        // laptop panel, an ultrawide, and the small System Settings preview alike.
        let emojiSize = minEdge * 0.20
        let textSize = minEdge * 0.115
        let subtitleSize = minEdge * 0.040
        let hasEmoji = !display.emoji.isEmpty

        return VStack(spacing: minEdge * 0.045) {
            if hasEmoji {
                Text(display.emoji)
                    .font(.system(size: emojiSize))
                    .shadow(color: .black.opacity(0.45), radius: emojiSize * 0.08, y: emojiSize * 0.02)
            }

            Text(display.text)
                .font(.system(size: textSize, weight: .light, design: .default))
                .tracking(textSize * 0.005)
                .foregroundStyle(Color(white: 0.97))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                // Long statuses wrap first, then shrink — down to about a third of the
                // starting size before anything would be clipped.
                .minimumScaleFactor(0.34)
                .shadow(color: .black.opacity(0.5), radius: textSize * 0.06, y: textSize * 0.015)
                .frame(maxWidth: width * 0.80)

            if let subtitle = display.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: subtitleSize, weight: .regular, design: .default))
                    .tracking(subtitleSize * 0.04)
                    .foregroundStyle(Color(white: 0.66))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: width * 0.7)
            }
        }
        .padding(minEdge * 0.06)
    }
}

/// Wraps `DriftScreenView` in a `TimelineView` so the app can render it without
/// managing a frame clock. The saver does not use this — it feeds `phase` directly.
public struct DriftScreenTimelineView: View {
    public var display: DisplayStatus
    private let start: Date

    public init(display: DisplayStatus, start: Date = Date()) {
        self.display = display
        self.start = start
    }

    public var body: some View {
        TimelineView(.animation) { context in
            DriftScreenView(
                display: display,
                phase: context.date.timeIntervalSince(start)
            )
        }
    }
}
