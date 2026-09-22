# hidipi

A free, open-source macOS command-line tool that enables HiDPI display modes with one command, making text and icons sharper and clearer.

[English](README.md) | [简体中文](README.zh-CN.md)

## What Problem Does It Solve?

Do any of these sound familiar?

- You plugged a 4K monitor into your Mac and everything looks soft and blurry. You'd love to switch the UI to HiDPI, but System Settings simply doesn't offer that option;
- You remote-desktop into a Mac mini with no monitor attached, and the only way to get a crisp HiDPI picture is buying an HDMI dummy plug;
- The guides you found online tell you to buy BetterDisplay, patch system files, or disable SIP — risky and a hassle.

hidipi exists to solve exactly these problems. It does two things:

1. **Unlock hidden HiDPI modes (real displays)** — macOS already ships HiDPI modes; it just doesn't show them in System Settings. hidipi lists them and switches safely.
2. **Create a HiDPI virtual display (Apple Silicon)** — no HDMI monitor or dummy plug needed; your remote desktop can use it directly.

And you **don't** need: paid software, sudo, modified system files, a disabled SIP, or any third-party dependencies (pure Python standard library).

## Installation

Requirements: macOS + [uv](https://docs.astral.sh/uv/), run in a **local terminal on your logged-in desktop** (sandboxed terminals may not see any displays).

From the project directory:

```sh
uv tool install .
```

After installing, `hidipi` works from any directory. If the command is not found, make sure uv's tool bin directory (usually `~/.local/bin`) is in your PATH.

```sh
# Verify the install and see where backups and logs live
hidipi paths
```

> For development you can skip installing and run `uv run hidipi ...` from the repo. Both share the same user data (`~/.config/hidipi/`).
> The old `hidpi` command still works as a compatibility alias for `hidipi`.

## Quick Start (Three Steps)

### Step 1: See the available HiDPI modes

```sh
hidipi list
```

This lists each display's HiDPI modes (logical size, render resolution, refresh rate). Add `--all` to also see normal-DPI modes.

### Step 2: Preview safely for 20 seconds

```sh
hidipi enable --size 1920x1080
```

- Your current display settings are **automatically backed up** before anything changes, so you can always go back;
- By default it previews for 20 seconds: type `y` + Enter to keep it, or press `Ctrl+C` (or let the countdown end) to restore automatically.

### Step 3: Keep it, long-term

```sh
# Option 1: keep the terminal window open; settings restore on Ctrl+C
hidipi enable --size 1920x1080 --keep

# Option 2: enable automatically at login, runs in the background, no terminal needed (recommended)
hidipi autostart install --size 1920x1080
hidipi autostart status
```

> **Important**: Option 1 requires the hidipi process to keep running — closing the terminal restores the original settings. For long-term use, choose Option 2.

## Common Scenarios

### Multiple displays / specific refresh rate

```sh
# With multiple displays, target one by its ID from `hidipi list`
hidipi enable --display 3 --size 1920x1080

# Request a refresh rate (fails loudly if unsupported — never silently downgrades)
hidipi enable --size 1920x1080 --refresh 60

# Omit --size to use the HiDPI mode matching your current logical size
hidipi enable

# Non-interactive: auto-restore after a fixed 5-second preview
hidipi enable --size 1920x1080 --seconds 5
```

### Remote desktop / no physical display

On Apple Silicon Macs you can create a standalone HiDPI virtual display, named **HiDPI Virtual Display**:

```sh
# Foreground preview for 20 seconds, then removed automatically; type y to keep
hidipi virtual --size 1920x1080

# Keep running; press Ctrl+C to remove the virtual display
hidipi virtual --size 1920x1080 --keep

# Create it automatically at login
# (if you previously installed autostart for a physical display, run hidipi autostart uninstall first)
hidipi autostart install --virtual --size 1920x1080
hidipi autostart status
```

Logical size `1920x1080` renders at `3840x2160` (2× pixels), 60 Hz by default.

Things to know:

- hidipi only creates the display — it is **not a remote-connection tool** and never enables Screen Sharing by itself;
- In your remote client, simply pick HiDPI Virtual Display;
- If a physical display is still attached, the virtual one is an extra desktop — it is not mirrored automatically;
- Stopping the only virtual display may briefly rearrange or drop your remote session — do it when reconnecting is easy.

### Enable at login (autostart)

Install once, and HiDPI turns on automatically every time you log into the desktop — no terminal to keep around:

```sh
# Enable (physical display mode)
hidipi autostart install --size 1920x1080

# Check status and recent logs
hidipi autostart status

# Preview the generated config without writing anything
hidipi autostart install --size 1920x1080 --dry-run

# Stop the background process, cancel autostart, restore pre-install settings (all backups kept)
hidipi autostart uninstall
```

Notes:

- Before running `enable` / `virtual` / `restore` manually, run `hidipi autostart uninstall` first, so two processes never fight over the display;
- Before upgrading or uninstalling the tool, also run `hidipi autostart uninstall` first;
- Logs live in `~/.config/hidipi/logs/` (`autostart.log` and `autostart-error.log`).

### Restore to original

Before every change, hidipi automatically saves a complete snapshot of your display settings to `~/.config/hidipi/backups/` — never overwritten:

```sh
# List historical backups
ls ~/.config/hidipi/backups/

# Restore using an actual file name
hidipi restore ~/.config/hidipi/backups/display-20260921-153000-abcdef12.json

# Back up the current settings without changing anything
hidipi backup
```

- Backups match displays by UUID, so restoring still targets the right screen after a reboot;
- If the original display isn't connected, restore fails with a clear error instead of guessing — reconnect and retry;
- `restore` also backs up the current state first, so you can experiment freely.

## Safety Guarantees

- **Backup before touching anything**: every switch is preceded by an automatic, read-back-verified backup; the display is only modified after verification passes.
- **Exit means restore**: `Ctrl+C`, closing the terminal, preview timeout, or a failed switch all restore the original settings and verify the result.
- **Roll back anytime**: every backup is kept; `hidipi restore <file>` takes you back to any point in history.
- **Nothing low-level is touched**: no EDID modification, no system config files — only display modes macOS already provides.

## Menu Bar Icon

While hidipi is running (preview, `--keep`, or the login autostart agent), a small hidipi icon appears in the macOS menu bar:

- Click it to see the active mode;
- **Restore & Quit** rolls everything back — exactly like pressing `Ctrl+C`.

To hide the icon, set the environment variable `HIDIPI_MENUBAR=0`. The icon is cosmetic: if it can't be shown (e.g. no desktop session), everything else still works.

## FAQ

**Q: What does enabling HiDPI actually do?**
UI elements keep the same size but render with twice the pixels (e.g. a 1920×1080 UI actually renders at 3840×2160), so text and icons look finer. It does not turn an ordinary panel into a 4K one — judge the improvement with your own eyes.

**Q: Why did my refresh rate drop after enabling HiDPI?**
Rendering pixels doubled, and some displays run out of bandwidth — e.g. a 4K panel may top out at 50 Hz in HiDPI (60 Hz in normal mode). Check modes ahead of time with `hidipi list`; you can also pass `--refresh 60`, which fails loudly if unsupported rather than silently downgrading.

**Q: Can I close the terminal?**
`enable` and `virtual` need their process alive: closing the terminal, pressing `Ctrl+C`, or the process exiting restores the original settings. For long-term use, `autostart install` runs in the background with no terminal and no Dock icon.

**Q: Something went wrong — how do I get completely back to normal?**

1. End the foreground process (`Ctrl+C`), or run `hidipi autostart uninstall` to stop the background service;
2. If needed, `hidipi restore <backup-file>` restores any historical backup.

**Q: Why does switching fail with a message about mirroring?**
hidipi never touches a mirrored display group. Uncheck mirroring in System Settings first, then run it again.

**Q: `hidipi list` shows no displays?**
Run it from a local terminal in your logged-in desktop session. In restricted sandboxes (IDE terminals, remote shells) the system APIs may see zero displays.

**Q: How is this different from BetterDisplay?**
hidipi is free, open source, dependency-free, and focused on exactly one thing: enabling HiDPI with automatic backup and rollback. BetterDisplay is a full-featured commercial product — if you need scaling, color controls, and more, use that.

**Q: Which systems are supported?**
macOS. HiDPI modes on physical displays use public system APIs; the virtual display feature uses a private macOS API and currently requires Apple Silicon (native ARM64 Python).

## Advanced & Development

```sh
# Custom backup directory (note: the flag goes before the subcommand)
hidipi --backup-dir /path/to/backups backup

# Run the automated tests (mocked interfaces — no real display switching)
uv run python -m unittest discover -s tests -v

# Real system-API smoke test (only from a local desktop terminal; never inside a sandbox)
HIDPI_NATIVE_TESTS=1 uv run python -m unittest discover -s tests -p test_native.py -v
```

Code layout: `cli.py` (command entry), `display.py` / `virtual.py` (physical / virtual display flows), `backup.py` (backup verification), `autostart.py` (login autostart), `runtime.py` (process & signal handling), `macos.py` (macOS system APIs), `modes.py` / `state.py` / `errors.py`.

Verified on a Mac mini (M4) / macOS 27.0 in 2026-09: mode switching and restore, preview-timeout rollback, cross-process backup restore, and virtual display create/remove all pass. Implementation details (lock files, state journal, failure retries) live in the source and tests.

## License

[MIT](LICENSE)

## References

- [Apple: CGDisplayCopyAllDisplayModes](https://developer.apple.com/documentation/coregraphics/cgdisplaycopyalldisplaymodes(_:_:))
- [Apple: Process-scoped display configuration rollback](https://developer.apple.com/documentation/coregraphics/cgconfigureoption/forapponly)
- [Apple: Display configuration transactions](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayTransactions.html)
- [Apple: LaunchAgent login items](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [uv: Standalone tool environments](https://docs.astral.sh/uv/concepts/tools/)
- [Chromium: CGVirtualDisplay API and headless detection](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)
