#!/bin/bash
#
# Checks what "Start Drift" will actually do on this Mac.
#
#   ./tools/test-screensaver.sh           report only — changes nothing, takes no screen
#   ./tools/test-screensaver.sh --start   also start the screensaver for one second
#
# Why this exists: whether launching ScreenSaverEngine still activates the screensaver has
# changed between macOS releases, and it is the one link in Start Drift that cannot be
# verified by reading code — it has to be tried, on a real screen, by you. The report half
# is read-only and safe to run any time; --start is the part that takes the screen.
#
# --start kills the engine after one second, which is well inside the password grace period
# reported below, so it should not leave you typing your password. If the grace period is 0
# ("immediately"), it will, and the script says so before doing anything.
set -euo pipefail

ENGINE="/System/Library/CoreServices/ScreenSaverEngine.app"
SAVER="$HOME/Library/Screen Savers/Back Soon.saver"
INDEX="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

bold "Screensaver"
if [ -d "$ENGINE" ]; then ok "ScreenSaverEngine is present"; else warn "ScreenSaverEngine is missing"; fi
if [ -d "$SAVER" ]; then ok "Back Soon.saver is installed"; else warn "Back Soon.saver is not installed — run ./install-saver.sh"; fi

# Match on this bundle's own path. macOS ships a screensaver called Drift of its own, at
# /System/Library/ExtensionKit/Extensions/Drift.appex, and it is listed in the very same
# "Other" section — which is why this one is called "Back Soon".
if [ -f "$INDEX" ] && grep -qa "Screen Savers/Back Soon.saver" "$INDEX"; then
    ok "Back Soon is the selected screensaver"
elif [ -f "$INDEX" ] && grep -qa "ExtensionKit/Extensions/Drift.appex" "$INDEX"; then
    warn "the selected screensaver is Apple's Drift, not this one — under 'Other' in System Settings > Screen Saver, choose 'Back Soon'"
else
    warn "Back Soon does not appear to be selected — pick it under 'Other' in System Settings > Screen Saver"
fi

echo
bold "Locking"
# Managed preferences first, then the per-host ones. That order is what CFPreferences
# itself does, and it matters: on a Mac managed by an employer these values are delivered
# by a configuration profile into /Library/Managed Preferences, and `defaults read
# com.apple.screensaver` never sees them.
MANAGED="/Library/Managed Preferences/$USER/com.apple.screensaver.plist"

read_pref() {  # read_pref <key>
    local key="$1" value=""
    if [ -f "$MANAGED" ]; then
        value=$(defaults read "$MANAGED" "$key" 2>/dev/null || true)
    fi
    if [ -z "$value" ]; then
        value=$(defaults -currentHost read com.apple.screensaver "$key" 2>/dev/null || true)
    fi
    printf '%s' "$value"
}

ASK=$(read_pref askForPassword)
IDLE=$(read_pref idleTime)

# The grace period is deliberately not read from the plists above. A profile can deliver
# askForPasswordDelay without it landing in the per-user managed domain — on this Mac it
# only appears in complete.plist — so reading the plists reports 0 when the real answer is
# 5, which is exactly the wrong direction to be wrong in. sysadminctl asks the system.
DELAY=$(sysadminctl -screenLock status 2>&1 | sed -n 's/.*delay is \([0-9][0-9]*\) seconds.*/\1/p')
[ -n "$DELAY" ] || DELAY=$(read_pref askForPasswordDelay)

if [ "$ASK" = "1" ]; then
    if [ -n "$DELAY" ]; then
        ok "password required, $DELAY seconds after the screensaver starts"
    else
        ok "password required after the screensaver starts (grace period unknown)"
    fi
else
    warn "no password required — stepping away will NOT lock this Mac"
fi
echo "  · screensaver starts after ${IDLE:-?} seconds of idle"
if [ -f "$MANAGED" ] && defaults read "$MANAGED" askForPassword > /dev/null 2>&1; then
    echo "  · enforced by a configuration profile — not changeable locally"
fi

# Display sleep matters as much as the screensaver delay: if the display turns off first,
# the screensaver never gets a lit screen to draw on and nobody sees your status.
DISPLAY_SLEEP=$(pmset -g | awk '/ displaysleep/ {print $2}')
echo "  · display sleeps after ${DISPLAY_SLEEP:-?} minutes"

if [ "${1:-}" != "--start" ]; then
    echo
    echo "Run with --start to actually start the screensaver for one second."
    exit 0
fi

echo
bold "Starting the screensaver for one second"
echo "Press ctrl-C now to abort."
sleep 2
open -a "$ENGINE"
sleep 1
if pgrep -x ScreenSaverEngine > /dev/null || pgrep -f legacyScreenSaver > /dev/null; then
    RESULT="ok"
else
    RESULT="failed"
fi
killall ScreenSaverEngine 2>/dev/null || true
echo
if [ "$RESULT" = "ok" ]; then
    ok "the screensaver started — Start Drift will work"
else
    warn "the screensaver did not start; Drift will report the same and end the session"
fi
