import SwiftUI

#if canImport(DriftCore)
import DriftCore
#endif

/// The Drift screen: a shop's closed sign, hung on two chains, saying where you went.
///
/// Drawn rather than drafted in: every part of it is a vector, so it is sharp on a
/// laptop panel and on a 5K display, and there is no asset to ship inside a sandboxed
/// screensaver bundle.
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

    public init(display: DisplayStatus, phase: Double, now: Date = Date()) {
        self.display = display
        self.phase = phase
        self.now = now
    }

    public static let background = Color(red: 0.0392, green: 0.0392, blue: 0.0392)   // #0A0A0A
    public static let primaryText = Color(red: 0.949, green: 0.949, blue: 0.941)     // #F2F2F0
    public static let secondaryText = Color(red: 0.549, green: 0.549, blue: 0.529)   // #8C8C87
    /// The board itself: a shade off the wall behind it, so its edge reads without a
    /// border doing all the work.
    public static let board = Color(red: 0.086, green: 0.090, blue: 0.098)
    /// Painted edge, and the chains.
    private static let paint = Color(red: 0.949, green: 0.949, blue: 0.941).opacity(0.42)
    private static let chain = Color(red: 0.549, green: 0.549, blue: 0.529).opacity(0.65)

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
    /// enough that no pixel holds the same glyph all afternoon.
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

                VStack(spacing: 0) {
                    chains(metrics)
                    eyes(metrics)
                        .offset(y: metrics.eyeSize * 0.42)
                        .zIndex(1)
                    board(metrics)
                }
                // The whole thing swings from the hook, the way it actually would.
                .rotationEffect(.degrees(tiltDegrees), anchor: .top)
                .offset(x: drift.width, y: metrics.hangTop + drift.height)

                hook(metrics)
                    .offset(y: metrics.hangTop - metrics.hookSize * 0.55 + drift.height)
                    .offset(x: drift.width)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .background(DriftScreenView.background)
        .ignoresSafeArea()
    }

    // MARK: Parts

    /// The screw eye the sign hangs from. Drawn separately from the swinging group so it
    /// stays still while the sign moves under it.
    private func hook(_ m: Metrics) -> some View {
        Circle()
            .strokeBorder(DriftScreenView.chain, lineWidth: m.chainWidth)
            .frame(width: m.hookSize, height: m.hookSize)
    }

    /// Two chains in a V from the hook to the board's top corners. Dashed rather than
    /// solid: at any real viewing distance the gaps read as links.
    private func chains(_ m: Metrics) -> some View {
        Canvas { context, canvasSize in
            let top = CGPoint(x: canvasSize.width / 2, y: 0)
            let inset = m.boardWidth * 0.17
            for x in [inset, m.boardWidth - inset] {
                var path = Path()
                path.move(to: top)
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                context.stroke(
                    path,
                    with: .color(DriftScreenView.chain),
                    style: StrokeStyle(
                        lineWidth: m.chainWidth,
                        lineCap: .round,
                        dash: [m.chainWidth * 2.1, m.chainWidth * 1.5]
                    )
                )
            }
        }
        .frame(width: m.boardWidth, height: m.chainHeight)
    }

    /// The screw eyes the chains hang off. Without these the chains end in mid-air just
    /// above the board, which reads as a mistake rather than as a sign.
    private func eyes(_ m: Metrics) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: m.boardWidth * 0.17 - m.eyeSize / 2)
            eye(m)
            Spacer()
            eye(m)
            Spacer().frame(width: m.boardWidth * 0.17 - m.eyeSize / 2)
        }
        .frame(width: m.boardWidth)
    }

    private func eye(_ m: Metrics) -> some View {
        Circle()
            .strokeBorder(DriftScreenView.chain, lineWidth: m.chainWidth)
            .frame(width: m.eyeSize, height: m.eyeSize)
    }

    private func board(_ m: Metrics) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: m.corner, style: .continuous)
                .fill(DriftScreenView.board)
            // The painted edge, inset the way a signwriter would leave it.
            RoundedRectangle(cornerRadius: m.corner * 0.72, style: .continuous)
                .strokeBorder(DriftScreenView.paint, lineWidth: m.edgeWidth)
                .padding(m.edgeInset)

            content(m)
                .padding(.horizontal, m.edgeInset + m.boardWidth * 0.07)
                .padding(.vertical, m.edgeInset + m.boardHeight * 0.09)
        }
        .frame(width: m.boardWidth)
        // A taller board for a longer message rather than a squeezed one: a two-line sign
        // gets the nominal height, and a three-line custom message gets a bigger board,
        // the way a signwriter would have cut one. Past the ceiling the type shrinks.
        .frame(minHeight: m.boardHeight, maxHeight: m.boardHeight * 1.5)
    }

    private func content(_ m: Metrics) -> some View {
        VStack(spacing: m.statusSize * 0.28) {
            Text(display.text)
                .font(.system(size: m.statusSize, weight: .semibold))
                .tracking(m.statusSize * 0.01)
                .foregroundStyle(DriftScreenView.primaryText)
                .lineLimit(3)
                // A long custom message wraps first, then shrinks — never clips, and
                // never grows past the board's edge.
                .minimumScaleFactor(0.42)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let returnTime = display.returnTime {
                Text(DriftFormat.backAround(returnTime, now: now))
                    .font(.system(size: m.returnSize, weight: .regular))
                    .foregroundStyle(DriftScreenView.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    // MARK: Metrics

    /// Every dimension in one place, derived from the screen so the same sign hangs
    /// correctly on a laptop panel, a 5K display, a portrait monitor and the
    /// thumbnail-sized preview System Settings draws.
    struct Metrics {
        let boardWidth: CGFloat
        let boardHeight: CGFloat
        let chainHeight: CGFloat
        let hangTop: CGFloat
        let hookSize: CGFloat
        let chainWidth: CGFloat
        let eyeSize: CGFloat
        let corner: CGFloat
        let edgeInset: CGFloat
        let edgeWidth: CGFloat
        let statusSize: CGFloat
        let returnSize: CGFloat

        init(size: CGSize) {
            let minEdge = min(size.width, size.height)
            statusSize = min(max(minEdge * 0.078, 15), 78)
            // Sized off the type as well as the screen. The type is clamped — 78pt is as
            // large as a status ever gets, because past that it is no easier to read from
            // across a room — so a board sized off the screen alone ends up as a mostly
            // empty rectangle on a 5K display. A sign is as big as its lettering needs.
            boardWidth = min(size.width * 0.44, size.height * 0.78, statusSize * 9.2)
            boardHeight = boardWidth * 0.48
            chainHeight = size.height * 0.10
            hookSize = max(minEdge * 0.022, 6)
            // Hung so the board's middle sits a little above the screen's, the way a sign
            // on a door does.
            hangTop = (size.height - chainHeight - boardHeight) * 0.42 + hookSize
            chainWidth = max(minEdge * 0.0035, 1)
            eyeSize = max(minEdge * 0.013, 4)
            corner = boardWidth * 0.028
            edgeInset = boardWidth * 0.035
            edgeWidth = max(minEdge * 0.0028, 1)
            returnSize = min(max(statusSize * 0.37, 10), 30)
        }
    }
}
