# Drift

A small personal macOS utility: a digital "Back soon" sign. When you leave your desk, Drift
shows where you went, in large quiet type, as your screensaver.

```
   Out for lunch

   Back around 1:35 PM
```

Pick a status, pick how long, press Start Drift. That is the whole app. It runs from the
menu bar, has no Dock icon, no accounts, no backend and no analytics. It is built for one
Mac: this one.

## What it does

- **Three taps to leave.** Four fixed statuses (Lunch, Break, Meeting, Away) or a one-line
  custom message; a duration chip or a picked time; Start Drift.
- **Shows it as a real screensaver**, so macOS can hold the lock behind it while your
  status stays on screen.
- **Never shows an outdated time.** Once the return time passes, the line becomes
  "Expected back shortly" — but Drift keeps showing your status, because lunch running
  long is still lunch.
- **Ends when you come back.** Dismissing the screensaver ends the session; the menu-bar
  icon goes back to hollow and the screen goes back to "Away from desk".
- **Nothing leaves this Mac.** No account, no token, no backend, no network request, and
  no access to your calendar, contacts or anything else macOS would have to ask about.

## Requirements

- macOS 15 or later (developed and verified on macOS 26.5.2, Apple Silicon).
- Command Line Tools for Xcode. **Full Xcode is not required.**

## Building and running

```bash
./build.sh          # release build into ./build
./build.sh debug    # unoptimised
swift test          # the tests
```

Then:

```bash
open build/Drift.app
```

Drift appears in the menu bar as a moon — hollow when idle, filled while a session is
running. There is no Dock icon and no window; click the menu-bar item.

**If you cannot find the icon**, macOS decides where a new status item goes. On first run
Drift asks for a slot among your other menu-bar icons, because the default is the gap
beside the notch, which is easy to mistake for the app never launching. Drag it anywhere
with ⌘ held and macOS remembers. To check whether it is there at all:

```bash
./tools/menubar-probe.sh
```

That asks the real app where its item landed and whether its popover opens, because
nothing outside the process can see a status item on this Mac — `screencapture` needs
Screen Recording permission and `log show` needs Full Disk Access.

To keep it around, drag `build/Drift.app` to `/Applications` or `~/Applications`. Launch at
login only works from a stable location.

### A note on `xcodebuild`

**This project has never been built with `xcodebuild`, because Xcode is not installed on
this Mac** — only Command Line Tools, which do not include `xcodebuild`. The build is
`swiftc` driven by `build.sh`, and the tests run under `swift test` using **swift-testing**
(the CLT toolchain ships `Testing.framework` but not `XCTest.framework`). Both were
actually run and both pass.

If you install Xcode later, `Package.swift` opens directly in it and will build and test
`DriftCore`. The two bundles would still be assembled by `build.sh`, since SwiftPM cannot
produce a `.app` or a loadable `.saver`.

## The popover

```
Drift                                    ⚙

What are you doing?
┌────────────┐ ┌────────────┐
│   Lunch    │ │   Break    │
└────────────┘ └────────────┘
┌────────────┐ ┌────────────┐
│  Meeting   │ │   Away     │
└────────────┘ └────────────┘
Write a custom message…

Back in
[5m] [10m] [15m] [20m]
[30m] [45m] [1 hr] [Custom]
Back at 1:35 PM

┌──────────────────────────┐
│       Start Drift        │
└──────────────────────────┘
```

Start Drift stays disabled until both a status and a duration are picked. Nothing else in
the popover starts Drift — choosing a preset selects it and no more.

Return triggers Start Drift, Escape closes the popover, and Tab walks the buttons with a
visible focus ring. Whatever you picked last is already selected the next time you open
the popover; it is never acted on by itself.

**Custom** under *Back in* reveals an hour-and-minute field, not a calendar. A time that
has already gone by today means that time tomorrow.

While a session is running the popover shows it instead of the form:

```
Drift                                    ⚙

Out for lunch
Back at 1:35 PM

┌──────────────────────────┐
│        End Drift         │
└──────────────────────────┘
┌──────────────────────────┐
│         +10 min          │
└──────────────────────────┘
```

`+10 min` extends from the return time while it is still ahead, and from now once it has
passed — ten more minutes always means ten minutes from here.

## Installing the screensaver

```bash
./build.sh
./install-saver.sh
```

That copies `Back Soon.saver` into `~/Library/Screen Savers` (per-user, no admin password),
removes any earlier `Drift.saver` install, and restarts `WallpaperAgent` so macOS notices
it.

Then **open System Settings › Screen Saver and choose "Back Soon"**, which appears under
**Other**. This step cannot be scripted on macOS 26 — the choice lives in a binary plist
inside `~/Library/Application Support/com.apple.wallpaper/`, and writing to it by hand would
mean rewriting your wallpaper configuration. Settings › Open macOS Screen Saver Settings
takes you there, and the popover says so under Start Drift if the selection is missing.

**Why the screensaver is called "Back Soon" and not "Drift".** macOS ships a screensaver of
its own called Drift — `/System/Library/ExtensionKit/Extensions/Drift.appex`, the colourful
moiré one — and it is listed in the same **Other** section. Two entries called "Drift" in
one list cannot be told apart, and picking the wrong one gives you an animation that knows
nothing about your status, with nothing on screen to say so. So this one carries a name
Apple does not use.

The screensaver reads whatever Drift last published to
`~/Library/Application Support/Drift/status.json`. It reaches no network and reads nothing
else — it runs inside macOS's sandboxed `legacyScreenSaver` host, and all it can do is read
that one file. See [FEASIBILITY.md](FEASIBILITY.md) for how that was verified, including
why the file works where an App Group cannot.

After a rebuild, re-run `./install-saver.sh` to replace the installed copy. Expect the
first start or two afterwards to be flaky: that script kills `WallpaperAgent` and the
screensaver host, and they take a moment to load the new bundle.

## The screen

A shop's closed sign, hung on two chains from a screw eye, with your status painted on it:

```
                    ○
                 ╱     ╲
        ┌───────────────────────┐
        │                       │
        │     Out for lunch     │
        │  Back around 1:35 PM  │
        │                       │
        └───────────────────────┘
```

Every part of it is a vector — board, chains, screw eyes, painted edge — so there is no
image asset to ship inside a sandboxed screensaver bundle and nothing to go soft on a
Retina display. Solid `#0A0A0A` wall, board a shade off it, cream `#F2F2F0` lettering and
`#8C8C87` for the return time, all of it SF Pro.

The board is sized off the *lettering*, not the screen: the status is clamped at 78pt
because past that it is no easier to read across a room, so a board sized off the screen
alone would be a mostly empty rectangle on a 5K display. It comes out at about nine times
the type size on every display — the same sign on a bigger wall. A long custom message
wraps to three lines and the board grows to take them, the way a signwriter would have cut
a taller one; past that the type shrinks rather than clipping.

**It swings.** A hanging sign only moves because something moved it, so this is a decaying
pendulum rather than a loop: a 3° kick when the sign goes up — somebody just flipped it
over and left — damping to rest within about fifteen seconds, and then a 1.1° nudge every
three and a half minutes, the way a draught catches a sign in a doorway. Between kicks it
hangs still.

That is also the cheap version. The screensaver only redraws at frame rate while the sign
is actually moving, which is about ten per cent of the time; the rest of the time it
redraws twice a second, and that is for the clock rather than the motion.

Nothing on this screen depends on the animation clock advancing. At `phase` 0 the sign
hangs at its just-been-flipped angle and reads perfectly, and it would go on reading
perfectly if the host never gave it another frame — `tools/saver-loadtest.swift` asserts
exactly that, by counting lit pixels before calling `animateOneFrame` at all. An earlier
version faded the text in over the first second and therefore drew a blank screen on its
first frame, which is indistinguishable from a broken screensaver.

The whole composition also wanders about 14pt over roughly seven minutes as burn-in
insurance. That is a fifth of a point per second: far below what the eye reads as movement,
far enough that no pixel holds the same glyph all afternoon.

Every display gets its own instance of the screensaver, each reading the same file, so all
of them show the same sign.

**Drift keeps the display awake while a session is running.** It has to: this Mac turns its
display off after five minutes, and a sign on a dark screen is not a sign — that mismatch
is what "it works sometimes" looks like from across a room. It holds
`PreventUserIdleDisplaySleep`, the assertion a video player holds, and releases it the
moment the session ends. It does not and cannot delay the Mac locking: the password clock
starts when the screensaver does, and is untouched by this. Closing the lid or pressing the
power button still sleeps the Mac immediately. The cost is that a laptop on battery keeps
its screen lit while you are away.

## Starting the screensaver, and locking

Start Drift does two things in order: publish the status, then start the screensaver. That
order is the whole trick — `status.json` is written synchronously before the engine
launches, so the saver comes up already showing the status you just picked rather than the
previous one. If the engine fails to start, Drift ends the session rather than leaving you
believing your Mac is showing a status it is not, and says so the next time you open the
popover.

**The screensaver is the only way to do this**, and it is worth being precise about why. An
ordinary app window runs in your logged-in session, so while it is up the Mac is by
definition *not* locked. The screensaver is the other way round: macOS draws it *over* a
locked session, so it goes on showing your status while the Mac is genuinely
locked behind it. There is no third option — no app can draw on the macOS lock screen
itself, because `loginwindow` renders it in a session of its own.

Drift does not touch any security setting to make this work. Whether a password is required
after the screensaver begins, and after how long, is macOS's own **Require password after
screen saver begins** in System Settings › Lock Screen. To see what it will actually do
here, from a terminal and without launching the app:

```bash
./tools/test-screensaver.sh
```

That reports everything that has to be true: the engine is present, the screensaver is
installed *and selected*, whether a password is required and after how long, and when the
display sleeps. `--start` also starts the screensaver for one second.

If the screensaver is installed but not selected, the popover says so under Start Drift,
with a link straight to the right pane — because otherwise Start Drift shows somebody
else's screensaver and your status never appears anywhere.

### Two things that will make this look broken

**Picking Apple's Drift instead of "Back Soon".** They used to have the same name in the
same list; this one was renamed for exactly that reason. If the screensaver you get is a
colourful moiré pattern, that is Apple's. `tools/test-screensaver.sh` names which one is
selected, by path rather than by name.

**If the display sleeps before the screensaver starts, nobody ever sees your status.** The
two timers are independent, and the screensaver needs a lit screen. Display sleep has to be
the later of the two. Read both with the tool rather than with `defaults`: a configuration
profile delivers these into `/Library/Managed Preferences`, which
`defaults read com.apple.screensaver` does not look at, so it will happily report a local
value the system is overriding. When they are profile-managed, changing them locally will
not hold and it is a question for whoever manages the Mac.

## Launch at login

Settings → **Launch Drift at login**. This uses `SMAppService`, so macOS may ask you to
approve it in System Settings › General › Login Items.

Two caveats, both a consequence of Drift being ad-hoc signed (there is no Developer ID on
this Mac):

- Move `Drift.app` to `/Applications` or `~/Applications` first. From a build directory the
  registration may be unavailable.
- Rebuilding changes the code signature, which can invalidate the registration. If Drift
  stops launching at login after a rebuild, toggle it off and on again.

## Settings

| | |
|---|---|
| **Launch Drift at login** | via `SMAppService` |
| **Show return time on Drift screen** | show or hide the "Back around …" line |
| **Open macOS Screen Saver Settings** | where `Drift.saver` has to be selected by hand |
| **About Drift** | the standard macOS about panel |
| **Quit Drift** | |

That is all of it. There is nothing to configure about the statuses, the durations or the
screen.

## When it does not work

`~/Library/Application Support/Drift/events.log` holds the last sixty things Drift did —
sessions started, whether the screensaver came up, why a session ended. It records what
Drift did, never what you typed. It exists because Drift has no window to report trouble in
and the unified log needs Full Disk Access on this Mac, so without it an intermittent
failure leaves nothing behind to look at.

To exercise the real Start Drift path end to end, three times over:

```bash
DRIFT_PROBE=start build/Drift.app/Contents/MacOS/Drift
```

Each cycle reports whether the screensaver came up, whether it was *still* up four seconds
later, what was on it, and what was published after the session ended.
`DRIFT_PROBE=heckle` runs one session and knocks the screensaver down underneath it, which
is the failure a hand resting on the trackpad causes.

**The first five seconds are the fragile ones.** The screensaver dismisses on any input —
that is its whole job — and pressing Start Drift is input, so a hand still on the trackpad
takes the sign straight back down. Drift waits for the click to settle, starts the
screensaver, watches for three seconds, and starts it again if it went down, up to five
times. Once macOS has locked the session behind it, the sign is sticky: macOS then refuses
to take the screensaver down without your password.

## What Drift remembers

Two things, both in `co.drift.app` preferences: the last status and duration you picked,
and the one setting above. **A running session is not one of them** — it lives in memory
only, and quitting Drift publishes "Away from desk". If Drift is not running, nothing can
end a session, so nothing should be claiming one.

Should Drift be killed outright while a session is live, `status.json` is left behind
saying so. The screensaver stops believing such a payload twelve hours past its return
time, which is the one case where a session ends without Drift's help.

## Known limitations on this Mac

- `xcodebuild` is unavailable here; see above.
- Ad-hoc signing means rebuilds may re-prompt for Keychain access and may need
  launch-at-login re-toggled.
- The deployment target is macOS 15.0, pinned by the CLT's MacOSX15.5 SDK, even though this
  Mac runs 26.5.
- Selecting the screensaver, and testing lock, wake and a second display, need you —
  [FEASIBILITY.md](FEASIBILITY.md) lists them explicitly.

## Uninstalling

```bash
# 1. Quit Drift (menu-bar item -> gear -> Quit Drift), and turn off launch at login first,
#    or remove it manually afterwards in System Settings > General > Login Items.

# 2. Remove the screensaver, and pick a different screensaver in System Settings first.
rm -rf ~/Library/"Screen Savers"/"Back Soon.saver"

# 3. Remove the app.
rm -rf /Applications/Drift.app ~/Applications/Drift.app   # wherever you put it

# 4. Remove the published status file and its folder.
rm -rf ~/Library/Application\ Support/Drift

# 5. Remove preferences (the remembered choices and the one setting).
defaults delete co.drift.app
killall cfprefsd
```

Drift stores nothing else: no token, no Keychain item, no caches outside the two locations
above, and no permissions to revoke.

## Layout

```
Package.swift                 DriftCore + its tests (this is what `swift test` runs)
build.sh                      builds Drift.app and Back Soon.saver with swiftc
install-saver.sh              installs Back Soon.saver into ~/Library/Screen Savers
Sources/
  DriftCore/                  pure Foundation, no AppKit — the testable half
    DriftSession.swift           the model, the display rule, and the wording
    DriftSettings.swift          the setting, the four presets, the durations
    StatusStore.swift            state, persistence, publishing
    SharedStatusFile.swift       status.json — the app/screensaver contract
  DriftShared/
    DriftScreenView.swift        the screen itself
  DriftApp/
    DriftAppMain.swift           AppKit entry point
    AppDelegate.swift            launch, teardown, the invisible main menu, DRIFT_PROBE
    MenuBarController.swift      the status item and the popover
    PopoverView.swift            the setup form and the active session
    DriftController.swift        starting, ending, and noticing you came back
    SettingsView.swift           five rows
    ScreenSaverLauncher.swift    starting the screensaver; is ours the selected one?
    LaunchAtLogin.swift          SMAppService
  DriftSaver/
    DriftScreenSaverView.swift   the ScreenSaverView subclass, built as Back Soon.saver
tools/
  menubar-probe.sh            asks the real app where its status item is; does the popover open?
  saver-loadtest.swift        loads the .saver the way macOS does; renders frames
  render-ui.sh                renders the app's views offscreen, in both appearances
  test-screensaver.sh         checks what Start Drift will actually do on this Mac
  verify-end-to-end.sh        app -> status.json -> .saver, using the real binaries
```

`DriftScreenView` takes an explicit `phase` in seconds rather than using SwiftUI's
animation engine, because implicit SwiftUI animation cannot be relied on to tick inside
`legacyScreenSaver`; the screensaver feeds `phase` from `animateOneFrame()`. It also takes
`now` rather than reading the clock, so the return line can be rendered deterministically
in tests and in the offscreen renders.
