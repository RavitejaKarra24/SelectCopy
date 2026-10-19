#!/bin/bash
# Removes only targets marked by install.sh; settings are always preserved.
set -euo pipefail

fail() { printf 'SelectCopy: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || fail 'Run as your login user, not with sudo.'
case "${HOME:-}" in /*) ;; *) fail 'HOME must be an absolute path.' ;; esac
[ -d "$HOME" ] || fail 'HOME is not a directory.'

LABEL=local.select-copy.agent
MARKER=local.select-copy.installer
APP="$HOME/Applications/SelectCopy.app"
CLI="$HOME/.local/bin/select_copy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="gui/$(id -u)/$LABEL"
owned() {
    [ ! -L "$1" ] &&
        [ "$(/usr/bin/xattr -p "$MARKER" "$1" 2>/dev/null)" = "$LABEL" ]
}
exists() { [ -e "$1" ] || [ -L "$1" ]; }
value() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

managed_plist=false
if owned "$PLIST" && [ -f "$PLIST" ] &&
    [ "$(value "$PLIST" Label)" = "$LABEL" ] &&
    [ "$(value "$PLIST" ProgramArguments.0)" = "$APP/Contents/MacOS/SelectCopy" ]; then
    managed_plist=true
fi

if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
    [ "$managed_plist" = true ] || fail 'Service is loaded but its plist is not managed; refusing to unload or delete anything.'
    /bin/launchctl bootout "$SERVICE" || {
        /bin/launchctl print "$SERVICE" >/dev/null 2>&1 && fail 'Could not unload service; nothing removed.'
        :
    }
fi
for ((attempt = 0; attempt < 50; attempt++)); do
    if ! /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then break; fi
    /bin/sleep 0.1
done
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then fail 'Service did not unload; nothing removed.'; fi

skipped=false
if exists "$PLIST"; then
    if [ "$managed_plist" = true ]; then
        /bin/rm -f "$PLIST"
    else
        printf 'Preserving unmanaged LaunchAgent: %s\n' "$PLIST" >&2
        skipped=true
    fi
fi
if exists "$CLI"; then
    if owned "$CLI" && [ -f "$CLI" ]; then
        /bin/rm -f "$CLI"
    else
        # This installer creates a regular executable, never a symlink.
        printf 'Preserving unmanaged CLI target (including symlinks): %s\n' "$CLI" >&2
        skipped=true
    fi
fi
if exists "$APP"; then
    if owned "$APP" && [ -d "$APP" ] &&
        [ "$(value "$APP/Contents/Info.plist" CFBundleIdentifier)" = "$LABEL" ]; then
        /bin/rm -rf "$APP"
    else
        printf 'Preserving unmanaged app target: %s\n' "$APP" >&2
        skipped=true
    fi
fi
printf 'Managed SelectCopy installation removed.\n'
printf 'Settings preserved: %s\n' "$HOME/Library/Application Support/SelectCopy/settings.json"
printf 'Shell startup files and Accessibility permissions were not changed.\n'
[ "$skipped" = false ] || exit 1
