import AppKit
import SwiftUI

#if canImport(DriftCore)
import DriftCore
#endif

/// The Drift screen: a shop's closed sign, hung on two chains, saying where you went,
/// with your name in the corner.
///
/// Drawn rather than drafted in: the sign, the chains, the corner light and the grain on
/// the board are all generated here, so they are sharp on a laptop panel and on a 5K
/// display. The one thing that cannot be drawn — the avatar — is carried as a literal
/// rather than as a bundle resource, for the reasons in `DriftAvatar`.
///
/// `phase` is the elapsed time in seconds and is supplied by the host rather than derived
/// from SwiftUI's animation engine, because inside `legacyScreenSaver` SwiftUI's implicit
/// animations cannot be relied on to tick.
///
/// Nothing here is allowed to *depend* on `phase` advancing. An earlier version faded the
/// text in over the first second, which meant a screen that had not yet been given an
/// animation frame rendered at zero opacity — indistinguishable from a broken
/// screensaver. `phase` now only tilts the sign and, much later, nudges it a few points
/// for burn-in: at `phase` 0 the sign hangs at a plausible just-been-flipped angle and
/// reads perfectly, and it would go on reading perfectly if the clock never advanced
/// again. `tools/saver-loadtest.swift` checks exactly that.
public struct DriftScreenView: View {

    public var display: DisplayStatus
    public var phase: Double
    /// Passed in rather than read here so the return line can be rendered
    /// deterministically in tests and previews.
    public var now: Date
    /// Whose sign this is. Injected rather than read from `DriftIdentity` inside the body
    /// so the render harness can pin it and get the same PNG on any Mac.
    public var name: String
    public var role: String

    public init(
        display: DisplayStatus,
        phase: Double,
        now: Date = Date(),
        name: String = DriftIdentity.name,
        role: String = DriftIdentity.role
    ) {
        self.display = display
        self.phase = phase
        self.now = now
        self.name = name
        self.role = role
    }

    // MARK: Palette

    public static let background = Color(white: 0.0431)                 // #0B0B0B
    public static let primaryText = Color.white                         // #FFFFFF
    public static let secondaryText = Color(red: 0.655, green: 0.651, blue: 0.624)  // #A7A69F

    /// The board's face, top and bottom. The design lays a 90%-transparent #181818 over
    /// the wall; both ends of that are composited here into opaque colours instead, so
    /// the board stays opaque over the corner light behind it rather than letting it
    /// bleed through.
    private static let boardTop = Color(white: 0.0941)                  // #181818
    private static let boardBottom = Color(white: 0.0482)               // #0C0C0C
    private static let boardEdge = Color(white: 0.5098).opacity(0.2)    // #828282 @ 20%
    /// The chains, and the rim of the hook they hang from.
    private static let chainTop = Color(white: 0.518)                   // #848484
    private static let chainBottom = Color(white: 0.565)                // #909090
    private static let hookFill = Color(white: 0.1855)                  // #2F2F2F
    private static let hookRimTop = Color(white: 0.443)                 // #717171
    /// The plate the avatar sits on, and its edge.
    private static let avatarPlate = Color(white: 0.239)                // #3D3D3D
    private static let avatarEdge = Color(white: 0.5098)                // #828282

    // MARK: Type

    /// The design asks for DM Sans (the sign, the name) and Mona Sans (the return line).
    /// Neither ships with macOS, so each is asked for by name and falls back to the system
    /// face when it is not installed — which is the case on a stock Mac. Resolved once:
    /// `NSFont(name:)` is a font-book lookup, and the body runs thirty times a second.
    private static let hasSignFace = NSFont(name: signFace, size: 12) != nil
    private static let hasReturnFace = NSFont(name: returnFace, size: 12) != nil
    private static let signFace = "DM Sans"
    private static let returnFace = "Mona Sans"

    private static func sign(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        hasSignFace
            ? .custom(signFace, size: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    private static func returnLine(_ size: CGFloat) -> Font {
        hasReturnFace ? .custom(returnFace, size: size) : .system(size: size)
    }

    // MARK: The swing

    /// A hanging sign only moves because something moved it.
    ///
    /// So this is not a loop. It is a decaying pendulum kicked at intervals: a firm one
    /// when the sign goes up — somebody just flipped it over and left — and a much smaller
    /// one every few minutes after that, the way a draught catches a sign in a doorway.
    /// Between kicks it hangs still.
    ///
    /// That is the honest version of the movement and also the cheap one. The host only
    /// redraws every frame while the sign is actually swinging, which is about fifteen
    /// seconds in every three and a half minutes; the rest of the time it redraws twice a
    /// second, and that is for the clock, not the motion.
    private static let firstKick = 3.0
    private static let draughtKick = 1.1
    private static let period = 2.6
    private static let decay = 6.0
    /// Past this the tilt is under a twentieth of a degree — visibly at rest.
    public static let settlesAfter: Double = 22
    /// How often a draught comes along.
    private static let kickInterval: Double = 210

    /// Time since the last kick, and how hard it was.
    private static func swing(at phase: Double) -> (elapsed: Double, amplitude: Double) {
        guard phase > 0 else { return (0, firstKick) }
        let kicks = (phase / kickInterval).rounded(.down)
        return (phase - kicks * kickInterval, kicks == 0 ? firstKick : draughtKick)
    }

    /// Whether the sign is still moving enough to be worth drawing at frame rate. The
    /// screensaver asks this rather than guessing.
    public static func isSwinging(at phase: Double) -> Bool {
        swing(at: phase).elapsed <= settlesAfter
    }

    public var tiltDegrees: Double {
        let (elapsed, amplitude) = DriftScreenView.swing(at: phase)
        return amplitude
            * exp(-elapsed / DriftScreenView.decay)
            * cos(2 * .pi * elapsed / DriftScreenView.period)
    }

    /// Burn-in insurance, and nothing more: about 14pt over roughly seven minutes, which
    /// is a fifth of a point per second — far below what the eye reads as movement, far
    /// enough that no pixel holds the same glyph all afternoon. Applied to the corner
    /// badge too, at half the amplitude, since it is also lit type that never changes.
    private var wander: CGSize {
        CGSize(
            width: 14 * sin(phase / 420.0),
            height: 10 * sin(phase / 610.0 + 1.7)
        )
    }

    // MARK: Body

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let metrics = Metrics(size: size)
            let drift = wander

            ZStack(alignment: .top) {
                DriftScreenView.background
                cornerLight(metrics)

                ZStack(alignment: .top) {
                    chains(metrics)
                    // Hung below the apex, and drawn after the chains so it covers the
                    // last few points of them. The design does the same thing — its
                    // chains are one closed triangle whose bottom edge is behind the
                    // board — and it matters: a chain that stops exactly at the board's
                    // edge leaves two lit nubs sitting on the top border.
                    board(metrics).padding(.top, metrics.chainHeight)
                }
                // The whole thing swings from the hook, the way it actually would.
                .rotationEffect(.degrees(tiltDegrees), anchor: .top)
                .offset(x: drift.width, y: metrics.hangTop + drift.height)

                // Drawn after the board so it sits on top of the chains' apex, and
                // outside the swinging group so it stays put while the sign moves.
                hook(metrics)
                    .offset(x: drift.width, y: metrics.hangTop - metrics.hookSize / 2 + drift.height)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                if metrics.showsBadge {
                    badge(metrics)
                        .padding(metrics.badgeInset)
                        .offset(x: drift.width / 2, y: drift.height / 2)
                }
            }
            .clipped()
        }
        .background(DriftScreenView.background)
        .ignoresSafeArea()
    }

    // MARK: Parts

    /// Two soft pools of light in the top corners, so the wall the sign hangs on is lit
    /// from somewhere rather than being a flat black field.
    ///
    /// The design draws these as white discs under a 200px Gaussian blur. A blur that
    /// wide relative to the disc flattens it into very nearly a Gaussian falloff, which
    /// is what these stops approximate — and a radial gradient costs a fraction of what
    /// an actual `.blur` of that radius would every time the view is rebuilt.
    private func cornerLight(_ m: Metrics) -> some View {
        // A Gaussian sampled at fifths, which is what a 200pt blur over a 205pt disc
        // comes out as once the blur has swallowed the disc's edge. `lightRadius` is
        // three sigma, so the last stop really is dark.
        let stops = Gradient(stops: [
            .init(color: .white.opacity(0.0498), location: 0),
            .init(color: .white.opacity(0.0416), location: 0.20),
            .init(color: .white.opacity(0.0242), location: 0.40),
            .init(color: .white.opacity(0.0099), location: 0.60),
            .init(color: .white.opacity(0.0028), location: 0.80),
            .init(color: .white.opacity(0), location: 1),
        ])
        // Centred a little above the top edge, as in the design.
        return ZStack {
            ForEach([0.0, 1.0], id: \.self) { x in
                RadialGradient(
                    gradient: stops,
                    center: UnitPoint(x: x, y: -0.035),
                    startRadius: 0,
                    endRadius: m.lightRadius
                )
            }
        }
    }

    /// The screw eye the sign hangs from: a dark disc with a rim lit from above, drawn
    /// over the point where the two chains meet.
    private func hook(_ m: Metrics) -> some View {
        Circle()
            .fill(DriftScreenView.hookFill)
            .overlay {
                Circle().strokeBorder(
                    LinearGradient(
                        colors: [DriftScreenView.hookRimTop, DriftScreenView.background],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: m.hookRimWidth
                )
            }
            .frame(width: m.hookSize, height: m.hookSize)
    }

    /// Two chains in a V from the hook down past the board's top corners.
    ///
    /// Drawn to the full triangle of the design — a little taller than the gap the board
    /// leaves — so both ends finish underneath the board rather than on its edge.
    private func chains(_ m: Metrics) -> some View {
        Canvas { context, canvasSize in
            let top = CGPoint(x: canvasSize.width / 2, y: 0)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [DriftScreenView.chainTop, DriftScreenView.chainBottom]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: canvasSize.height)
            )
            for x in [m.chainInset, m.boardWidth - m.chainInset] {
                var path = Path()
                path.move(to: top)
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                context.stroke(
                    path,
                    with: shading,
                    style: StrokeStyle(lineWidth: m.chainWidth, lineCap: .round)
                )
            }
        }
        .frame(width: m.boardWidth, height: m.chainDrawHeight)
    }

    private func board(_ m: Metrics) -> some View {
        let shape = RoundedRectangle(cornerRadius: m.corner)
        // The board is drawn *behind* the lettering rather than beside it in a ZStack,
        // and that is load-bearing. A `Shape` fill takes every point it is offered, so a
        // ZStack of fills and text stretches to whatever height the screen has going
        // spare — which is how the board ended up half again as tall as the design.
        // As a background it takes its size from the type instead.
        return content(m)
            .padding(.horizontal, m.textInset)
            .padding(.vertical, m.edgeWidth + m.boardHeight * 0.09)
            // A taller board for a longer message rather than a squeezed one: a two-line
            // sign gets the design's height, and a three-line custom message gets a
            // bigger board, the way a signwriter would have cut one.
            .frame(width: m.boardWidth, height: nil)
            .frame(minHeight: m.boardHeight)
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [DriftScreenView.boardTop, DriftScreenView.boardBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                grain.clipShape(shape)
            }
            .overlay { shape.strokeBorder(DriftScreenView.boardEdge, lineWidth: m.edgeWidth) }
    }

    /// The board's texture. A painted board is not a flat field of one colour, and at
    /// this size a perfectly flat one reads as a rectangle rather than as a thing.
    @ViewBuilder
    private var grain: some View {
        if let tile = Grain.tile {
            // One speck per point, and 3.3% of one at that. Both numbers are measured
            // off the design rather than guessed: a flat band of its board has a mean
            // 4.1/255 above the underlying gradient and a standard deviation of 2.4,
            // and premultiplied-white noise added at alpha a gives exactly 128a and
            // 73.6a. a = 0.033 satisfies both.
            Image(decorative: tile, scale: 1)
                .resizable(resizingMode: .tile)
                .opacity(0.033)
                .blendMode(.plusLighter)
        }
    }

    private func content(_ m: Metrics) -> some View {
        VStack(spacing: m.statusSize * 0.14) {
            Text(display.text)
                .font(DriftScreenView.sign(m.statusSize, .semibold))
                .lineSpacing(m.statusSize * 0.10)
                .foregroundStyle(DriftScreenView.primaryText)
                .lineLimit(3)
                // A long custom message wraps first, then shrinks — never clips, and
                // never grows past the board's edge.
                .minimumScaleFactor(0.42)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let returnTime = display.returnTime {
                Text(DriftFormat.backAround(returnTime, now: now))
                    .font(DriftScreenView.returnLine(m.returnSize))
                    .foregroundStyle(DriftScreenView.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    /// Name and role in the bottom corner, next to the avatar. Signed work: the sign says
    /// where somebody went, and this says who.
    private func badge(_ m: Metrics) -> some View {
        HStack(spacing: m.badgeGap) {
            avatar(m)
            VStack(alignment: .leading, spacing: m.nameSize * 0.12) {
                Text(name)
                    .font(DriftScreenView.sign(m.nameSize, .medium))
                    .foregroundStyle(DriftScreenView.primaryText)
                Text(role)
                    .font(DriftScreenView.sign(m.roleSize, .regular))
                    .foregroundStyle(DriftScreenView.secondaryText)
            }
            .lineLimit(1)
        }
    }

    private func avatar(_ m: Metrics) -> some View {
        let shape = RoundedRectangle(cornerRadius: m.avatarCorner)
        return ZStack {
            DriftScreenView.avatarPlate
            // Under the avatar rather than over it, which is where the design puts it:
            // its tile carries a 1.2pt edge and then an image that fills the tile
            // completely, so the edge only ever shows through where the avatar does not
            // reach — which, with the avatar in place, is nowhere. It earns its keep in
            // the fallback below.
            shape.strokeBorder(DriftScreenView.avatarEdge, lineWidth: m.avatarEdgeWidth)
            if let image = DriftAvatar.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                // Only reachable if the embedded PNG fails to decode, which it cannot
                // do on a Mac that got this far — but a hole in the corner would be a
                // worse answer than initials.
                Text(monogram)
                    .font(DriftScreenView.sign(m.avatarSize * 0.4, .semibold))
                    .foregroundStyle(DriftScreenView.primaryText)
            }
        }
        .frame(width: m.avatarSize, height: m.avatarSize)
        .clipShape(shape)
    }

    private var monogram: String {
        let initials = name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
        return initials.isEmpty ? "?" : initials.uppercased()
    }

    // MARK: Grain

    /// A tile of seeded noise, built once and tiled across the board.
    ///
    /// Generated rather than shipped for the same reason the rest of the screen is drawn
    /// rather than exported: it is a handful of bytes of arithmetic instead of an asset
    /// that a sandboxed screensaver has to find. The seed is fixed, so every render of a
    /// given frame is byte-identical and the offscreen harness in `tools/` can diff them.
    private enum Grain {
        static let side = 128

        static let tile: CGImage? = make()

        private static func make() -> CGImage? {
            // xorshift64, so the tile is the same on every machine and every run. A
            // system RNG would give a different board on every rebuild.
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                // White premultiplied by its own alpha: a speck of light rather than a
                // grey square, so the tile lifts the board where it is bright and leaves
                // it alone where it is not.
                let value = UInt8(truncatingIfNeeded: state >> 33)
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
                pixels[index + 3] = value
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: side,
                height: side,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }
    }

    // MARK: Metrics

    /// Every dimension in one place, derived from the screen so the same sign hangs
    /// correctly on a laptop panel, a 5K display, a portrait monitor and the
    /// thumbnail-sized preview System Settings draws.
    ///
    /// The ratios come straight off the design, which is a 560pt board on a 1440x900
    /// screen. Everything on the board is a fraction of the board's width, so the sign
    /// scales as one object.
    struct Metrics {
        let boardWidth: CGFloat
        let boardHeight: CGFloat
        /// The gap the chains have to cross: apex to the board's top edge.
        let chainHeight: CGFloat
        /// How far they are actually drawn, which is to the closed triangle's corners,
        /// a little way behind the board.
        let chainDrawHeight: CGFloat
        let chainInset: CGFloat
        let chainWidth: CGFloat
        let hangTop: CGFloat
        let hookSize: CGFloat
        let hookRimWidth: CGFloat
        let corner: CGFloat
        let edgeWidth: CGFloat
        let textInset: CGFloat
        let statusSize: CGFloat
        let returnSize: CGFloat
        let lightRadius: CGFloat
        let showsBadge: Bool
        let badgeInset: CGFloat
        let badgeGap: CGFloat
        let avatarSize: CGFloat
        let avatarCorner: CGFloat
        let avatarEdgeWidth: CGFloat
        let nameSize: CGFloat
        let roleSize: CGFloat

        init(size: CGSize) {
            let minEdge = min(size.width, size.height)

            // The board the screen would like: 38.9% of the width, or 62.2% of the
            // height on a screen too short for that.
            let wanted = min(size.width * 0.389, size.height * 0.622)
            // The type is clamped — 78pt is as large as a status ever gets, because past
            // that it is no easier to read from across a room — and the board then
            // follows the type rather than the screen, so a 5K display gets a bigger
            // sign rather than a mostly empty rectangle. A sign is as big as its
            // lettering needs.
            statusSize = min(max(wanted * 0.10, 15), 78)
            boardWidth = min(wanted, statusSize * 10)

            boardHeight = boardWidth * 0.50
            chainHeight = boardWidth * 0.182
            chainDrawHeight = boardWidth * 0.2375
            // Where the chains end: 3.1% in from the board's corners, which is where the
            // design's triangle meets it. Crossing the board's top edge 15.2% in.
            chainInset = boardWidth * 0.03125
            chainWidth = max(boardWidth * 0.00714, 1)
            hookSize = boardWidth * 0.0857
            hookRimWidth = max(hookSize * 0.042, 1)
            corner = boardWidth * 0.0571
            edgeWidth = max(boardWidth * 0.00714, 1)
            // Looser than the design's text box, which is hugging "Out for lunch" at
            // 18.9% a side and says nothing about anything longer. At 12% the design's
            // own status still sets identically — it is centred and nowhere near the
            // edge — while "Away from desk", the status the screen shows most of the
            // time, stays on one line instead of wrapping.
            textInset = boardWidth * 0.12
            returnSize = boardWidth * 0.0429

            // Hung so the board's middle sits a little above the screen's, the way a
            // sign on a door does.
            hangTop = (size.height - chainHeight - boardHeight) * 0.432
            lightRadius = minEdge * 0.652

            // The badge is screen furniture rather than part of the sign, so it is sized
            // off the screen and clamped hard: a name at 40pt is a name at 40pt whether
            // it is on a laptop or a 5K panel. Below 400pt the screen is the preview
            // thumbnail in System Settings, where a 12pt name is illegible clutter.
            showsBadge = minEdge >= 400
            avatarSize = min(max(minEdge * 0.0444, 26), 56)
            badgeInset = min(max(minEdge * 0.0356, 18), 44)
            badgeGap = avatarSize * 0.30
            avatarCorner = avatarSize * 0.30
            avatarEdgeWidth = max(avatarSize * 0.03, 1)
            nameSize = avatarSize * 0.40
            roleSize = avatarSize * 0.35
        }
    }
}
