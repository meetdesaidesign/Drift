# Drift

A small personal macOS utility. When you step away from your Mac, Drift shows whatever
meeting you are in — or a custom status — in large, quiet type as your screensaver.

```
                              🍜

                        Out for lunch

                     Back around 2:30 PM
```

It runs from the menu bar, has no Dock icon, no accounts, no backend and no analytics. It
is built for one Mac: this one.

## What it does

- Shows a status full screen: large emoji, large status text, smaller return time, on deep
  charcoal with a slow drifting glow.
- Two sources: your **Calendar** (the meeting currently in progress, read locally via
  EventKit), or a **Custom** status you type, with six editable one-click presets.
- **Never shows an expired status.** When a status expires, when nothing is on your
  calendar, or when private mode is on, it shows "Away from desk" instead.
- **Nothing leaves this Mac.** No account, no token, no backend, and no network request
  anywhere in Drift.
- Ships as **both** a real macOS screensaver (`Drift.saver`) and a full-screen window you
  can open on demand from the menu bar.

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

Drift appears in the menu bar as 🌙 (or as your current status emoji). There is no Dock
icon and no window — click the menu-bar item.

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

## Your calendar as your status

Switch the popover's source to **Calendar** and Drift shows whatever meeting is in progress:

```
                              🗓️
                        Design review
                     Back around 3:30 PM
```

macOS will ask for Calendar permission the first time — Drift only asks at the point it
actually needs it, so if you only ever use custom statuses you will never see the prompt.
If you decline and change your mind, Settings › Calendar has a button through to
**System Settings › Privacy & Security › Calendars**.

### Google, iCloud, Exchange

There is no Google Calendar integration, and there does not need to be one. Drift reads
**every calendar in every account Calendar.app syncs** — so if your Google account is added
in System Settings › Internet Accounts, Drift is already showing your Google meetings.
Same for iCloud and Exchange. Settings › Calendar lists the accounts it can see, so you can
check rather than guess.

This is deliberate: it means Drift has no OAuth client, no stored token, no refresh loop and
no network code at all. The syncing is macOS's problem, and macOS is better at it. To hide a
calendar from Drift, uncheck it in Calendar.app.

If you want to confirm what EventKit sees from a terminal:

```
./tools/list-calendars.sh
```

It prints every account, its type, its calendars and how many events are in the next 24
hours. Run it in **Terminal.app** — it needs to show a Calendars permission prompt, which
cannot appear from a non-interactive shell.

### When Drift and your calendar disagree

If Drift says nothing is on your calendar and your calendar says otherwise, there are only
three possible causes, and they need different fixes: the account is not in Calendar.app at
all, the account is there but the event has not synced, or the event is there and one of
Drift's own rules dropped it. Rather than guess, turn on the calendar dump:

```
touch ~/Library/Application\ Support/Drift/.debug-calendar
open build/Drift.app
cat ~/Library/Application\ Support/Drift/calendar-debug.txt
```

Drift then writes, on every calendar read, exactly what EventKit handed it: each account and
its calendars, every event in ±24h with its dates, all-day flag, status and your RSVP, and a
per-event verdict in Drift's own terms — "all-day — ignored by design", "has not started
yet", "IN PROGRESS — eligible to be your status". The report ends with the answer the UI is
showing, so a disagreement between the two is visible in one file.

Delete the marker file to turn it off. Nothing is written without it.

Note that `./build.sh` re-signs the app ad-hoc, which changes its code identity — so macOS
treats a freshly built Drift as a new app and **asks for Calendar permission again**. That is
expected after a rebuild, not a bug.

How it decides:

- Only a meeting **actually in progress** counts.
- The meeting's **end time becomes both the return time and the expiry**, so the status
  clears itself when the meeting does.
- **All-day events are ignored** — "Q3 planning week" is not a reason you left your desk,
  and it would sit there all day.
- **Meetings you have declined are ignored**, as are cancelled ones.
- When meetings **overlap, the one ending soonest wins** — that is the one you are most
  likely actually in.
- An **untitled event** shows "In a meeting" rather than a blank screen.
- An **emoji is inferred from the title** — lunch, coffee, calls, 1:1s, focus blocks,
  appointments, travel, PTO and so on — falling back to 🗓️.
- Drift re-reads every two minutes, **and immediately whenever your calendar changes**.

If the calendar read fails, Drift keeps showing the cached meeting — but only until its end
time, after which it falls back to "Away from desk".

Meeting titles can be sensitive. **Private mode** (Settings › General) makes Drift always
show "Away from desk" instead, and it is enforced before anything is written to disk, so a
real title never reaches the file the screensaver reads.

## Installing the screensaver

```bash
./build.sh
./install-saver.sh
```

That copies `Drift.saver` into `~/Library/Screen Savers` (per-user, no admin password) and
restarts `WallpaperAgent` so macOS notices it.

Then **open System Settings › Screen Saver and choose Drift**, which appears under
**Other**. This step cannot be scripted on macOS 26 — the choice lives in a binary plist
inside `~/Library/Application Support/com.apple.wallpaper/`, and writing to it by hand would
mean rewriting your wallpaper configuration.

The screensaver reads whatever Drift last published to
`~/Library/Application Support/Drift/status.json`. It reads no calendar and reaches no
network — it runs inside macOS's sandboxed `legacyScreenSaver` host, and all it can do is
read that one file. See [FEASIBILITY.md](FEASIBILITY.md) for how that was verified,
including why the file works where an App Group cannot.

After a rebuild, re-run `./install-saver.sh` to replace the installed copy.

### If you would rather not use the screensaver

Everything works without it. **Show Drift** in the menu-bar popover opens the same visual
as a full-screen window across all your displays, and Settings › General can open it
automatically after a chosen period of inactivity.

That window is a plain app window: it never draws a password field or an unlock prompt, it
takes no power assertions and changes no energy settings, so it cannot imitate the macOS
lock screen and cannot delay or prevent your Mac from locking or sleeping normally. It
closes on any key, click, scroll or mouse movement, and closes itself if the screen locks
or the Mac sleeps.

## Launch at login

Settings › General → **Launch Drift at login**. This uses `SMAppService`, so macOS may ask
you to approve it in System Settings › General › Login Items.

Two caveats, both a consequence of Drift being ad-hoc signed (there is no Developer ID on
this Mac):

- Move `Drift.app` to `/Applications` or `~/Applications` first. From a build directory the
  status may read "Unavailable".
- Rebuilding changes the code signature, which can invalidate the registration. If Drift
  stops launching at login after a rebuild, toggle it off and on again. The same is true of
  the Calendar permission: a rebuild can make macOS ask again.

## Settings

| | |
|---|---|
| **Launch at login** | via `SMAppService`, with the live status shown |
| **Default source** | Calendar or Custom on startup |
| **Fallback text** | what to show when there is nothing valid; default "Away from desk" |
| **Show return time** | show or hide the "Back around …" line |
| **Private mode** | always show the fallback, never the real status |
| **Idle activation** | optional delay before the full-screen window opens by itself |
| **Preview Drift** | opens the full-screen view without syncing first |
| **Calendar** | access state, what is on now, last check, errors, and how the rules work |
| **Presets** | add, edit, remove and reset the one-click presets |

Private mode is enforced where it counts: Drift resolves the status *before* writing
`status.json`, so with private mode on your real status text never reaches that file at
all. There is a test for this.

## Known limitations on this Mac

- `xcodebuild` is unavailable here; see above.
- Ad-hoc signing means rebuilds may re-prompt for Keychain access and may need
  launch-at-login re-toggled.
- The deployment target is macOS 15.0, pinned by the CLT's MacOSX15.5 SDK, even though this
  Mac runs 26.5.
- Calendar emoji are inferred from event titles by keyword. Unmatched titles get 🗓️.
- Rebuilding may make macOS re-ask for Calendar permission, since the code signature
  changes.
- Selecting the screensaver, testing lock/wake, checking a second display, and granting
  Calendar access all need you — [FEASIBILITY.md](FEASIBILITY.md) lists them explicitly.

## Uninstalling

```bash
# 1. Quit Drift (menu-bar item -> Quit), then turn off launch at login in Settings first,
#    or remove it manually afterwards in System Settings > General > Login Items.

# 2. Remove the screensaver, and pick a different screensaver in System Settings first.
rm -rf ~/Library/"Screen Savers"/Drift.saver

# 3. Remove the app.
rm -rf /Applications/Drift.app ~/Applications/Drift.app   # wherever you put it

# 4. Remove the published status file and its folder.
rm -rf ~/Library/Application\ Support/Drift

# 5. Remove preferences (custom status, settings, presets, cached calendar status).
defaults delete co.drift.app
killall cfprefsd
```

Drift stores nothing else: no token, no Keychain item, no caches outside the two locations
above. Revoke its Calendar access in System Settings › Privacy & Security › Calendars.

## Layout

```
Package.swift                 DriftCore + its tests (this is what `swift test` runs)
build.sh                      builds Drift.app and Drift.saver with swiftc
install-saver.sh              installs Drift.saver into ~/Library/Screen Savers
Sources/
  DriftCore/                  pure Foundation, no AppKit — the testable half
    DriftStatus.swift            the model, and every display rule in one function
    DriftSettings.swift          settings and presets
    StatusStore.swift            state, persistence, sync scheduling, publishing
    CalendarStatus.swift         event -> status rules, and title -> emoji (pure, no EventKit)
    SharedStatusFile.swift       status.json — the app/screensaver contract
  DriftShared/
    DriftScreenView.swift        the one full-screen visual, used by both bundles
  DriftApp/
    DriftAppMain.swift, AppDelegate.swift, DriftController.swift,
    MenuBarView.swift, SettingsView.swift, CalendarClient.swift (EventKit lives here only),
    FullScreenPresenter.swift, IdleMonitor.swift, LaunchAtLogin.swift
  DriftSaver/
    DriftScreenSaverView.swift   the ScreenSaverView subclass
tools/
  saver-loadtest.swift        loads the .saver the way macOS does; renders frames
  render-ui.sh                renders the app's views offscreen
  list-calendars.sh           prints the calendar accounts EventKit can see
  verify-end-to-end.sh        app -> status.json -> .saver, using the real binaries
```

`DriftScreenView` takes an explicit `phase` in seconds rather than using SwiftUI's
animation engine, because implicit SwiftUI animation cannot be relied on to tick inside
`legacyScreenSaver`. The app feeds `phase` from a `TimelineView`; the screensaver feeds it
from `animateOneFrame()`. One view, two hosts, no duplicated visual.
