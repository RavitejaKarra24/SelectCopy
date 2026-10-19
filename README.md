# SelectCopy

A local, native macOS menu-bar app that automatically copies selected text to the clipboard. Select text, release the mouse or selection keys, then paste wherever you need it—no manual Copy command required.

- Works with text exposed through macOS Accessibility, including ordinary webpages in Zen and Brave.
- Runs in the menu bar, with an optional login agent and an `on` / `off` / `status` CLI.
- Runs locally without an account, cloud service, or selection history.

Requires **macOS 13+** to run and **Swift 6+** to build. Install Xcode or Apple's Command Line Tools before building.

## Get the source

```bash
git clone https://github.com/RavitejaKarra24/SelectCopy.git
cd SelectCopy
```

## Build and try

From the project directory:

```bash
bash scripts/package_app.sh
open build/SelectCopy.app
```

Packaging produces `build/SelectCopy.app` (main executable: `SelectCopy`) and `build/select_copy` (CLI). Manual launch is for trying the app; install below for continuous operation and login startup. Quit a manually launched development copy before installing so two copies do not poll at once.

### Accessibility permission

In the app menu, choose **Grant Accessibility**, then enable **SelectCopy** under **System Settings > Privacy & Security > Accessibility**. Add the app there if it is not listed. Grant permission to the app, not the CLI or Terminal. For an installed copy, use `~/Applications/SelectCopy.app`.

On macOS 27, this permission is listed under **Privacy & Security > Device Control and Data Access**.

This is an unsigned/ad-hoc-signed local app, not a notarized distribution. Rebuilding or changing its path/signature may require removing and re-adding SelectCopy in Accessibility. A running LaunchAgent does not imply Accessibility permission has been granted.

If copying stops after an update, remove the old SelectCopy permission entry, add `~/Applications/SelectCopy.app` again, enable it, and restart the app. Simply toggling the old entry may not refresh its signature.

## Install and start at login

Run as your normal logged-in GUI user; **do not use sudo**:

```bash
bash scripts/install.sh
```

The installer first runs `scripts/package_app.sh`. Only after packaging and validation succeed does it unload an existing managed service and replace the installation. It installs:

| Item | Stable path |
| --- | --- |
| App | `~/Applications/SelectCopy.app` |
| CLI (copied executable) | `~/.local/bin/select_copy` |
| LaunchAgent | `~/Library/LaunchAgents/local.select-copy.agent.plist` |

The bundle identifier and LaunchAgent label are `local.select-copy.agent`. The agent runs the installed app executable directly, starts immediately and at each user login, and uses `RunAtLoad=true`, `KeepAlive=true`, and `ThrottleInterval=5`. It remains alive while copying is paused and restarts after unexpected exits, subject to launchd throttling. **Quit SelectCopy** in the menu unloads the agent for the current login session; it starts again at the next login. To restart sooner, rerun the installer. It is a per-user GUI agent, not a system daemon; it does not run while logged out. Standard output and error go to `/dev/null`, not captured text logs.

The installer enables, bootstraps, and kickstarts the agent. Run it again to rebuild/reinstall. If startup fails after files are installed, it reports the error; installation is not automatically rolled back.

No shell startup files are edited. If needed, add this to your shell configuration yourself, or use the CLI's full path:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Existing unrelated targets, including symlinks, are not overwritten. Installed files carry a private extended-attribute ownership marker; an unmarked app, CLI, or plist must be moved aside deliberately before installation. If a marker was stripped by a backup/copy tool, the scripts conservatively treat that target as unmanaged. A loaded service with this label but without a managed plist must be resolved manually.

## Control copying

```bash
select_copy on
select_copy off
select_copy status
```

`on` and `off` change the desired copying state; **they do not terminate or launch the app**. `off` only pauses copying, keeping the menu-bar app and LaunchAgent alive. The desired state persists in:

```text
~/Library/Application Support/SelectCopy/settings.json
```

The CLI can change this desired state even before the app is running, but does not launch it. Use the installer for login startup, or `open build/SelectCopy.app` for a manual launch. `status` is not a substitute for checking whether launchd has loaded the service:

```bash
launchctl print "gui/$(id -u)/local.select-copy.agent"
```

## Behavior and limitations

- Polls the focused accessibility element approximately every **0.5 seconds**; copying is not instantaneous.
- Apps must expose **`AXSelectedText`**, a selected range with `AXStringForRange`, or a text marker range with `AXStringForTextMarkerRange`, through macOS Accessibility. Text markers support ordinary webpage selections in Zen/Firefox as well as selections spanning multiple page elements. Some Chrome/Electron apps may need accessibility support enabled in that app; selections unavailable through Accessibility cannot be copied.
- There is **no synthetic Cmd+C fallback**. Secure text fields are skipped. Other sensitive text, including secrets in ordinary text fields, will still be copied; pause auto-copy when working with it.
- Copying waits until mouse buttons and selection modifiers are released. Selections larger than 1 MiB are ignored. An unchanged selection is not copied repeatedly.
- Automatic copying **overwrites the current clipboard**. Pause with `select_copy off` when you need to preserve it.
- Polling cannot detect every deselect/reselect cycle that occurs between samples. Removing `settings.json` restores the default **on** state.
- No cloud service or selection history. A local selection cache is used only to avoid repeatedly copying the same selection; it is not a history feature. Selected text is placed on the system clipboard, where other clipboard tools or OS features may access it.

## Development checks

Manual checks on macOS 27 verified webpage and input-field selections in **Zen** and **Brave Browser Beta**, including formatted webpage text and Unicode in Zen. Other apps depend on the Accessibility information they expose; these checks do not establish support for every website or browser version.

```bash
make format
make check       # Swift format lint, shell checks, plist validation, unit tests
make package
```

Tests use Swift Testing. `scripts/test.sh` also handles the Swift 6.4 Command Line Tools macro-plugin discovery issue; full Xcode needs no workaround. Recent toolchains may require macOS 14+ to run their bundled test framework (the app itself targets macOS 13+).

To use a local signing identity instead of ad-hoc signing, set `SIGNING_IDENTITY` when packaging/installing. Stable signing can avoid Accessibility re-authorization after rebuilds.

## Uninstall

```bash
bash scripts/uninstall.sh
```

The uninstaller bootouts the managed LaunchAgent before removing the managed plist, copied CLI, and app. It leaves unrelated targets and symlinks untouched, does not edit shell configuration, and does not revoke macOS Accessibility permissions. A separately launched development app is not terminated by uninstalling the LaunchAgent.

**Settings are preserved by default.** To reset the saved on/off preference, after uninstalling and quitting any development copy, manually remove only:

```text
~/Library/Application Support/SelectCopy/settings.json
```

Reinstallation otherwise retains your desired copying state. Build artifacts in this checkout are also preserved.
