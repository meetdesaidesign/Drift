import AppKit

/// The avatar in the corner of the screen.
///
/// Carried as base64 in source rather than as a file in `Contents/Resources`, and that is
/// deliberate. `DriftShared` is compiled into three different things — the menu-bar app,
/// the `.saver` bundle, and the two offscreen render harnesses in `tools/` — and only two
/// of those have a bundle to look in. A `.saver` also loads inside `legacyScreenSaver`,
/// which is sandboxed; a missing or unreadable resource there would show up as a hole in
/// the corner of the screen with nothing in the logs to say why. A literal cannot fail to
/// be found.
///
/// It costs about 6KB of source for that: 160x160 (enough for a 56pt tile on a Retina
/// panel) quantised to a 160-colour palette, which an illustration of flat shapes takes
/// without visible loss.
enum DriftAvatar {

    /// Decoded once. `nonisolated(unsafe)` because `NSImage` is not `Sendable` and this
    /// one is never mutated after it is built.
    nonisolated(unsafe) static let image: NSImage? = {
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return NSImage(data: data)
    }()

    private static let encoded = """
        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
        """
}
