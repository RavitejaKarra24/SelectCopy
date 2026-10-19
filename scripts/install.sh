#!/bin/bash
# Per-user installation; compatible with macOS Bash 3.2.
set -euo pipefail
umask 077

fail() { printf 'SelectCopy: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || fail 'Run as your login user, not with sudo.'
case "${HOME:-}" in /*) ;; *) fail 'HOME must be an absolute path.' ;; esac
[ -d "$HOME" ] || fail 'HOME is not a directory.'

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
LABEL=local.select-copy.agent
MARKER=local.select-copy.installer
APP="$HOME/Applications/SelectCopy.app"
CLI="$HOME/.local/bin/select_copy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/$LABEL"
STAGE=''
trap '[ -z "$STAGE" ] || /bin/rm -rf "$STAGE"' EXIT

owned() {
    [ ! -L "$1" ] &&
        [ "$(/usr/bin/xattr -p "$MARKER" "$1" 2>/dev/null)" = "$LABEL" ]
}
exists() { [ -e "$1" ] || [ -L "$1" ]; }
value() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# Never stop the working installation until packaging has succeeded.
[ -f "$ROOT/scripts/package_app.sh" ] || fail 'Missing scripts/package_app.sh.'
(cd "$ROOT" && /bin/bash scripts/package_app.sh)
[ -d "$ROOT/build/SelectCopy.app" ] || fail 'Packaging did not produce build/SelectCopy.app.'
[ -x "$ROOT/build/SelectCopy.app/Contents/MacOS/SelectCopy" ] || fail 'Missing app executable.'
[ -f "$ROOT/build/select_copy" ] && [ -x "$ROOT/build/select_copy" ] || fail 'Missing executable build/select_copy.'
[ "$(value "$ROOT/build/SelectCopy.app/Contents/Info.plist" CFBundleIdentifier)" = "$LABEL" ] || fail 'Unexpected app bundle identifier.'

# Refuse to overwrite unrelated files, directories, or symlinks.
if exists "$APP"; then
    owned "$APP" && [ -d "$APP" ] &&
        [ "$(value "$APP/Contents/Info.plist" CFBundleIdentifier)" = "$LABEL" ] ||
        fail "Unmanaged app target; move it aside first: $APP"
fi
if exists "$CLI"; then
    owned "$CLI" && [ -f "$CLI" ] || fail "Unmanaged CLI target; move it aside first: $CLI"
fi
if exists "$PLIST"; then
    owned "$PLIST" && [ -f "$PLIST" ] &&
        [ "$(value "$PLIST" Label)" = "$LABEL" ] &&
        [ "$(value "$PLIST" ProgramArguments.0)" = "$APP/Contents/MacOS/SelectCopy" ] ||
        fail "Unmanaged LaunchAgent target; move it aside first: $PLIST"
fi
/bin/launchctl print "$DOMAIN" >/dev/null 2>&1 || fail 'Run from a logged-in macOS GUI session.'
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
    exists "$PLIST" || fail "A service already uses $LABEL without a managed plist. Resolve it manually."
fi

/bin/mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
STAGE=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/select-copy-install.XXXXXX")
/usr/bin/ditto "$ROOT/build/SelectCopy.app" "$STAGE/SelectCopy.app"
/bin/cp "$ROOT/build/select_copy" "$STAGE/select_copy"
/bin/chmod 755 "$STAGE/select_copy"

# plutil serializes paths as strings, including XML special characters.
/usr/bin/plutil -create xml1 "$STAGE/agent.plist"
/usr/bin/plutil -insert Label -string "$LABEL" "$STAGE/agent.plist"
/usr/bin/plutil -insert ProgramArguments -array "$STAGE/agent.plist"
/usr/bin/plutil -insert ProgramArguments.0 -string "$APP/Contents/MacOS/SelectCopy" "$STAGE/agent.plist"
/usr/bin/plutil -insert RunAtLoad -bool true "$STAGE/agent.plist"
/usr/bin/plutil -insert KeepAlive -bool true "$STAGE/agent.plist"
/usr/bin/plutil -insert ThrottleInterval -integer 5 "$STAGE/agent.plist"
/usr/bin/plutil -insert StandardOutPath -string /dev/null "$STAGE/agent.plist"
/usr/bin/plutil -insert StandardErrorPath -string /dev/null "$STAGE/agent.plist"
/usr/bin/plutil -lint "$STAGE/agent.plist"
/bin/chmod 644 "$STAGE/agent.plist"
for target in "$STAGE/SelectCopy.app" "$STAGE/select_copy" "$STAGE/agent.plist"; do
    /usr/bin/xattr -w "$MARKER" "$LABEL" "$target"
done

if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
    /bin/launchctl bootout "$SERVICE" || {
        /bin/launchctl print "$SERVICE" >/dev/null 2>&1 && fail 'Could not unload existing service.'
        :
    }
fi
# bootout can return before the old service has fully disappeared.
for ((attempt = 0; attempt < 50; attempt++)); do
    if ! /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then break; fi
    /bin/sleep 0.1
done
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then fail 'Existing service did not unload; nothing replaced.'; fi

if exists "$APP"; then /bin/rm -rf "$APP"; fi
/bin/mv "$STAGE/SelectCopy.app" "$APP"
/bin/mv -f "$STAGE/select_copy" "$CLI"
/bin/mv -f "$STAGE/agent.plist" "$PLIST"

/bin/launchctl enable "$SERVICE"
loaded=false
for ((attempt = 0; attempt < 5; attempt++)); do
    if /bin/launchctl bootstrap "$DOMAIN" "$PLIST"; then loaded=true; break; fi
    if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then loaded=true; break; fi
    /bin/sleep 1
done
[ "$loaded" = true ] || fail "Installed, but bootstrap failed. Retry: launchctl bootstrap $DOMAIN \"$PLIST\""
started=false
for ((attempt = 0; attempt < 5; attempt++)); do
    if /bin/launchctl kickstart -k "$SERVICE"; then started=true; break; fi
    /bin/sleep 1
done
[ "$started" = true ] || fail "Installed, but kickstart failed. Retry: launchctl kickstart -k $SERVICE"
printf 'Installed and started SelectCopy. Grant Accessibility permission to SelectCopy.\n'
printf 'App: %s\nCLI: %s\nLaunchAgent: %s\n' "$APP" "$CLI" "$PLIST"
# shellcheck disable=SC2016 # Print a literal command for the user's shell.
printf '\nIf needed, add ~/.local/bin to PATH yourself:\n  export PATH="$HOME/.local/bin:$PATH"\n'
printf 'No shell startup files were changed. Use select_copy off to pause without stopping the app.\n'
