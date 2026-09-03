# Screensaver feasibility on this Mac

Findings from the spike that ran before Drift was built, plus what was verified afterwards
against the finished bundles.

**Verdict: the real `.saver` works on this machine, and it is the only implementation.**
An on-demand full-screen window was also built at one point; it was removed, because it
cannot do the one thing that matters — a window in your logged-in session is by definition
not a locked Mac.

## This machine

| | |
|---|---|
| macOS | 26.5.2 (build 25F84) |
| Architecture | arm64 |
| Swift | 6.1.2 (`swift-driver` 1.120.5) |
| SwiftPM | 6.1.0 |
| Xcode | **not installed** — Command Line Tools only |
| SDK used | MacOSX15.5 (the newest the CLT ships), deployment target macOS 15.0 |
| Code-signing identities | **none** (`security find-identity -v -p codesigning` → 0 valid identities) |
| System screensaver idle time | 300s |

## What was tested, and what happened

### 1. A `.saver` bundle can be built without Xcode — yes

`swiftc -emit-library -Xlinker -bundle` produces a genuine `Mach-O 64-bit bundle arm64`,
which is what `NSBundle`/`legacyScreenSaver` expects to `dlopen`. `ScreenSaver.framework`
ships headers and a `.tbd` in the CLT SDK, so no Xcode is needed to link against it.

### 2. The bundle loads and its Swift principal class is found — yes

`tools/saver-loadtest.swift` loads the built bundle exactly the way the screensaver host
does — `Bundle(path:)` → `load()` → `principalClass` → `init(frame:isPreview:)` — then
drives `animateOneFrame()` and renders offscreen PNGs:

```
OK  bundle loaded — co.drift.saver
OK  principalClass = DriftScreenSaverView
OK  instantiated DriftScreenSaverView at 1728x1117, 30fps
OK  startAnimation
OK  rendered build/preview/frame-003.0s.png (3456x2234)
ALL CHECKS PASSED
```

The SwiftUI content renders correctly inside the `ScreenSaverView`, including the fade-in,
the drifting gradient, and long-status wrapping and shrinking.

### 3. Ad-hoc signing is enough — yes, and this is the important one

There is no Developer ID on this Mac, so `Drift.saver` is ad-hoc signed (`codesign -s -`).
That normally stops third-party code loading into a system host. It works here because
`legacyScreenSaver.appex` is signed with:

```
com.apple.security.cs.disable-library-validation = true
```

which lets it load code that is not signed by a matching team.

### 4. The sandboxed screensaver can read Drift's status file — yes, verified directly

This was the riskiest assumption, so it was tested rather than inferred.
`legacyScreenSaver.appex` carries:

```
com.apple.security.app-sandbox = true
com.apple.security.temporary-exception.files.absolute-path.read-only = [ "/" ]
```

Two throwaway app bundles were built, identical except for that exception, both ad-hoc
signed, both reading `~/Library/Application Support/Drift/status.json`:

| Entitlements | Result |
|---|---|
| sandbox + read-only-`/` exception | `READ OK (141 bytes)` |
| sandbox only (control) | `READ DENIED … Operation not permitted` |

So the exception is what grants access, it works under ad-hoc signing, and the screensaver
host has it. **This is why Drift uses a plain JSON file instead of an App Group** — App
Groups need a real Team ID, which this Mac cannot provide.

That test also turned up a design-critical detail: inside the sandbox,
`FileManager.urls(for: .applicationSupportDirectory, …)` resolves to the process
*container* (`~/Library/Containers/…/Data/Library/Application Support`), not to the real
home directory. `SharedStatusFile` therefore builds the path from `getpwuid(getuid())`
instead. Using `FileManager` here would fail silently in the saver while working perfectly
in the app.

### 5. The whole chain works with the real app binary — yes

`tools/verify-end-to-end.sh` seeds a status into Drift's preferences, relaunches the built
`Drift.app`, and checks what it publishes, then loads the built `.saver` against it:

```
==> 1. A live custom status is published
  PASS  live status — published "Out for lunch"
==> 2. An already-expired status is never published
  PASS  expired status — published "Away from desk"
==> 3. A status with no expiry is published
  PASS  no-expiry status — published "Out for lunch"
==> 4. The built .saver reads what the app published
  PASS  .saver loaded and rendered the published status
END-TO-END: ALL CHECKS PASSED
```

## Still needs your hands — I could not verify these

These need either a GUI click or a hardware event, and one needs a permission I cannot
grant myself.

1. **Selecting Drift in System Settings › Screen Saver.** macOS 26 keeps the screensaver
   choice in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, a
   binary plist of provider records. Writing to it by hand would mean editing your
   wallpaper configuration, so `install-saver.sh` stops at installing the bundle and
   restarting `WallpaperAgent`. It appears under **Other**. macOS does not enumerate
   `~/Library/Screen Savers` until that pane is opened, which is why nothing referenced the
   bundle in the wallpaper store immediately after installing.

   This cost a round trip in practice. The bundle was originally called `Drift.saver`, and
   macOS ships `/System/Library/ExtensionKit/Extensions/Drift.appex` — also displayed as
   "Drift", and listed in the same **Other** section. Two identically named entries, one of
   them ours, five of ten items hidden behind "Show All": the wrong one gets picked, and the
   result is a screensaver that draws something perfectly normal while knowing nothing about
   your status. The bundle is now called `Back Soon.saver`.
2. **Starting, exiting, locking and waking.** Needs a real screensaver activation.
   This also covers the one link in **Start Drift** that cannot be settled by reading code:
   whether launching `/System/Library/CoreServices/ScreenSaverEngine.app` still activates
   the screensaver on this macOS. It has changed between releases, and its failure mode is
   to launch and immediately exit rather than to return an error — so `ScreenSaverLauncher`
   waits and re-checks the process list instead of trusting the launch, and reports
   "macOS did not start the screensaver" if it is gone. Verify with
   `./tools/test-screensaver.sh --start`, which takes the screen for one second.
3. **A second display.** This Mac had one display attached during the build.
4. **The popover's exact appearance.** `screencapture` fails with
   `could not create image from display` because the terminal lacks Screen Recording
   permission. As a substitute, `tools/render-ui.sh` renders the real views offscreen: the
   layout, control set and sizing are confirmed (`PopoverView` fits 340×324 with nothing
   picked, 340×346 with a status and duration selected, 340×408 with the custom message and
   the time picker revealed, 340×186 while a session is running; `SettingsView` 380×331),
   and SwiftUI's `ImageRenderer` confirms the labels. Neither offscreen renderer captures
   everything — `cacheDisplay` uses AppKit's drawing path and drops SwiftUI-drawn text in
   control-heavy views, while `ImageRenderer` marks AppKit-backed controls (the text field,
   the time stepper, the prominent buttons) unsupported and paints them yellow. So the
   popover is proven to build, lay out and size correctly, but its final look is yours to
   eyeball.

   **This limitation has already cost one bug**, so it is worth being concrete about. In an
   earlier version the popover's middle section was wrapped in a `ScrollView`, which has no
   intrinsic height. A popover sizes itself to fit its content, so the ScrollView reported
   an ideal height of zero and the entire middle collapsed; `.frame(maxHeight: 420)` only
   set a ceiling, not a height. The harness missed it because it forced a 700pt-tall frame.
   Worse, it *cannot* catch it: measured deliberately, an `NSHostingView` in an offscreen
   window reports the same `fittingSize` with and without the ScrollView, because the
   harness never goes through the popover's sizing path. This is why the current popover
   uses plain stacks rather than lazy grids — but popover layout still has to be checked in
   the running app.
5. **The popover's keyboard and pointer behaviour.** Return starting Drift, Escape closing
   the popover, Tab walking the buttons with a visible focus ring, and the hover and pressed
   states all need a real key press or a real pointer.
6. **The screensaver drawing inside the real host.** Verified as far as it can be from
   outside: `tools/saver-loadtest.swift` loads the installed bundle the way
   `legacyScreenSaver` does and now asserts that the screen is *not blank before a single
   animation frame has run*. That check exists because it caught a real bug — the text was
   faded in over the first second, keyed to elapsed time, so a screensaver that had not yet
   been given an animation frame drew nothing at all and looked broken. Nothing on that
   screen may depend on the animation clock.
7. **The session ending when you come back.** Drift ends it on the screensaver stopping —
   `com.apple.screensaver.didstop` and `com.apple.screenIsUnlocked`, with a process-list
   poll as a backstop — and all three need a real screensaver to have really started.
8. **Launch at login surviving a reboot.**

## Note on the Slack version

Drift originally read your Slack status through a private Slack app and a pasted user
token. That was removed in favour of reading the Mac's Calendar locally: no token, no
Keychain item, no network, and no workspace admin to ask. The Slack code, the
`KeychainStore` and their tests were deleted rather than left dormant, and any saved token
was removed from the Keychain. `StatusStore` clears the retired
`drift.cachedSlackStatus` preference key on load so a stale cached status cannot linger.
It is all recoverable from git history if it is ever wanted back.

## Note on the calendar version

Between the Slack version and this one, Drift read the Mac's Calendar through EventKit and
showed whatever meeting was in progress, with editable presets, expiry rules, private mode
and an inferred emoji. All of it was removed to make Drift a "Back soon" sign again: the
calendar client, its diagnostics, the event-selection and emoji-inference rules and their
tests were deleted rather than left dormant, the `NSCalendars*UsageDescription` keys are out
of `Info.plist`, and the app no longer links EventKit. `StatusStore` clears the retired
`drift.cachedCalendarStatus`, `drift.customStatus`, `drift.presets`, `drift.source` and
`drift.lastSyncDate` preference keys on load. It is all recoverable from git history if it
is ever wanted back.

## Known limitations on this Mac

- **`xcodebuild` cannot be run here at all.** There is no Xcode.app on disk, so the build
  is `./build.sh` (swiftc) and `swift test`. Both were run and both succeed. No claim is
  made about `xcodebuild`, because it was never run.
- **Ad-hoc signatures change on every rebuild.** `SMAppService` may need the
  launch-at-login toggle flipped again afterwards, which is why Settings reads the live
  `SMAppService.mainApp.status` rather than a stored boolean.
- **Deployment target is pinned to macOS 15.0** by the CLT's MacOSX15.5 SDK, even though
  this Mac runs 26.5. The binaries run natively; only newer-than-15.5 APIs are off limits.
- **Drift asks macOS for no permissions at all.** There is nothing to grant and nothing to
  revoke: no calendar, no contacts, no accessibility, no screen recording.
- **The screensaver reaches nothing.** By design: no network and no private state —
  `otool -L` confirms `Drift.saver` links only AppKit, SwiftUI, ScreenSaver, Combine and
  Foundation. All it can do is read `status.json`.
- **A session ends with Drift, not without it.** Quitting publishes "Away from desk"; being
  killed outright cannot. For that case the saver stops believing a payload twelve hours
  past its return time, which is the only expiry left anywhere in Drift.
