# HidiPi (Swift)

A Swift port of the Python hidipi (`/Users/devuser/GitHub/hidipi`): a pure menu-bar app —
one menu to enable HiDPI, everything restored automatically on quit.

- **Physical display HiDPI**: lists each display's hidden HiDPI modes and switches to them
- **Virtual display** (Apple Silicon): creates a HiDPI Virtual Display out of thin air, no HDMI device needed
- **Start at login**: launches at login (SMAppService)
- **Automatic restore**: in-memory snapshots plus app-only scope — quitting (or even killing)
  the app puts every setting back

## Build

Command Line Tools only (no Xcode needed), macOS 13+ / Apple Silicon:

```sh
scripts/build-app.sh        # produces dist/HidiPi-<version>.dmg
```

Open the DMG and drag HidiPi.app into Applications. You can also run `build/HidiPi.app` directly.

### Gatekeeper warning

The app is ad-hoc signed and not notarized, so on first launch Gatekeeper blocks it
("Apple cannot verify…"). Any of these unblocks it:

- **System Settings**: after seeing the block dialog, open System Settings → Privacy &
  Security, scroll down, and click **Open Anyway**.
- **Terminal**: `xattr -dr com.apple.quarantine /Applications/HidiPi.app`
- **Download via terminal** in the first place — `curl -LO <dmg url>` or
  `gh release download <tag> -R unfallenwill/hidipi` do not attach the quarantine
  attribute, so no prompt appears at all.

(Right-click → Open no longer bypasses this on current macOS.) Real notarization requires
an Apple Developer Program membership and a Developer ID certificate; without one the
build falls back to ad-hoc signing.

## Usage

After launching, an icon appears in the menu bar (a display outline with a 2×2 pixel array):

- **Display N ▸** submenu lists the available HiDPI sizes (✓ = current); displays in a mirror set are disabled
- **Virtual Display ▸** creates 1920×1080 / 2560×1440, or removes it
- **Start at Login** toggle
- **About HidiPi**
- **Quit (Restore Original Settings)**: physical displays return to their original modes, the virtual display is removed

Virtual display + Start at Login = automatic rebuild across reboots: a successful creation
records the size in `~/.config/hidipi/virtual.json`, and the app rebuilds it after its
login launch; only an explicit **Remove Virtual Display** in the menu clears the record.
An unexpected disappearance (e.g. the system reorganizing displays) keeps the record, so
the next login still rebuilds.

The safety model:

- Every change is preceded by an in-memory snapshot that is validated before anything is
  touched, and used to roll back on failure
- Physical switches use the app-only scope: even if the process is killed, macOS reverts
  the change automatically
- Quit / remove restores originals; quitting always restores — physical changes revert on
  process exit even if the orderly restore fails
- Shares `operation.lock` with the Python version: the two cannot run at the same time
  (whichever starts second refuses with a clear message)
- Only one modification at a time (physical or virtual), enforced in the state layer and
  guided by the menu

## Development

```sh
swift build            # build
swift test             # unit tests (pure logic)
```

Release: push a `v<version>` tag (e.g. `v0.3.2`) to trigger GitHub Actions — tests, DMG
packaging (version taken from the tag), SLSA build provenance, and a GitHub Release;
downloaders can verify the DMG's provenance with `gh attestation verify`.

Structure: `Sources/HidiPiCore` (pure logic: mode selection / snapshot validation),
`Sources/HidiPi` (the app: CG transactions, virtual display bridging, menu-bar UI),
`Sources/HidiPiIcon` (icon geometry, shared by the status bar and the icns),
`Sources/render-icon` (icns asset generation), `scripts/build-app.sh` (packaging).

Known quirk: the local swift 6.4-dev toolchain occasionally hits
`TestingMacros plugin not found` (even after a clean); passing the plugin path explicitly
works:

```sh
swift test -Xswiftc=-external-plugin-path \
  -Xswiftc='/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server'
```

## Differences from the Python version (intentional)

- No CLI and no 20-second preview countdown: a resident menu-bar app; quitting restores
- No on-disk backups: in-memory snapshots plus app-only auto-revert replace the backup
  files, and there is no restore-from-backup menu — process exit is the restore path
- Autostart via SMAppService (the app registers itself), no LaunchAgent written
- The icon is drawn programmatically from a single set of geometry (pixel-identical to
  `StatusIconTemplate.svg`), no PNGs bundled

## License

MIT (same as the Python version).
