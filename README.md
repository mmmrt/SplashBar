# SplashBar

A tiny macOS menu bar app that controls the lifecycle of a local [Splash](https://splash.inco.ai)
inference server (`splash serve`) — start, pause, resume, stop, restart — without touching a terminal.

Written in pure Swift + AppKit. **No Xcode project, no dependencies, no package manager.**
One shell script compiles it into a real `.app` bundle.

> Requires Apple Silicon (arm64) and macOS 13+.
> Developed and tested on an M5 Max / 128 GB machine running macOS 27.0.

---

## What it does

Splash runs as a background HTTP server on port `8000` (OpenAI-compatible API). Starting it by hand
means remembering flags, tailing logs, and hunting down PIDs when you want it to stop. SplashBar puts
all of that behind one menu bar icon.

- **Live status at a glance** — the menu bar icon has three states: *running*, *paused*, *stopped*.
  The dropdown shows decode speed (tok/s), draft acceptance rate, resident memory, and TTFT.
- **Pause without unloading** — sends `SIGSTOP` to freeze the server process. Memory stays resident,
  so resuming is instant instead of a ~12 s model reload. Useful when you need the memory back
  temporarily but don't want to pay the reload cost.
- **Correct by construction** — menu items are greyed out according to an explicit state machine, so
  you can't start a second server on an occupied port or pause something that isn't running.
- **Outlives the app** — the server is spawned in its own session (`setsid`). Quitting SplashBar does
  not kill the model, and the app re-adopts the running process on next launch.

## Features

| | |
|---|---|
| **Three-state menu bar icon** | Running / paused / stopped droplet, drawn with CoreGraphics (@1x/@2x/@3x) |
| **Optional model name** | Show or hide the model name next to the icon (toggle in the menu) |
| **Controls** | Start, Pause, Resume, Stop, Restart, Take over, Open Web UI, Copy API base URL |
| **Serve parameters** | Model, `--max-memory`, `--max-context`, API key, `--allowed-host`, `--no-webui` |
| **Login item** | Launch at login via `SMAppService` |
| **Quit guard** | Asks for confirmation; confirming stops the server and exits cleanly |
| **Take over** | Adopt a `splash serve` process you started manually in a terminal |

## Install

### 1. Build

```bash
git clone https://github.com/mmmrt/SplashBar.git
cd SplashBar
./build.sh
```

`build.sh` compiles both Swift sources, generates the icons, assembles
`~/Applications/SplashBar.app`, ad-hoc signs it, and strips the quarantine attribute.

Requires Xcode Command Line Tools (`xcrun swiftc`, `iconutil`).

### 2. Run

```bash
open ~/Applications/SplashBar.app
```

The app has no window and no Dock icon (`LSUIElement = 1`) — it lives entirely in the menu bar.

### 3. Optional: start at login

Menu → **Launch at Login**. This registers the app with `SMAppService`.

## Usage

Click the menu bar icon for the full menu. The top section shows live telemetry, the middle section
holds the controls, and the rest configures serve parameters.

### State machine

Which items are enabled depends only on five booleans (port responding, process owned by us, frozen,
starting, external). The full truth table is reproducible at any time with `--states`:

| State | Start | Pause | Stop | Restart | Take over | Web UI |
|---|---|---|---|---|---|---|
| Stopped | ✅ | ── | ── | ── | ── | ── |
| Running (managed) | ── | ✅ | ✅ | ✅ | ── | ✅ |
| Paused (managed) | ✅ | ── | ✅ | ✅ | ── | ── |
| Starting (loading) | ── | ── | ✅ | ✅ | ── | ── |
| Port held externally | ── | ── | ✅ | ✅ | ✅ | ✅ |

In the paused state the Start item is relabelled **Resume** — it sends `SIGCONT`; it does not spawn a
second process.

### Command line

```bash
~/Applications/SplashBar.app/Contents/MacOS/SplashBar <flag>
```

| Flag | Meaning |
|---|---|
| `--status` | State, serve args, tok/s, acceptance rate, memory, login item |
| `--start` | Start the server (detached; survives app exit) |
| `--pause` | Freeze the process group with `SIGSTOP` |
| `--resume` | Thaw with `SIGCONT` |
| `--stop` | Stop and clean up the whole process group |
| `--restart` | Stop then start |
| `--login-on` / `--login-off` | Register / unregister the login item |
| `--takeover` | Kill whatever holds port 8000 and adopt it |
| `--states` | Print the truth table plus the live measured state |
| `--dump-menu` | Build the real menu, run AppKit validation, print final enabled flags |
| `--help` | Help |

## Configuration

Stored at `~/Library/Application Support/SplashBar/config.json`:

```json
{
  "model": "incoai/Qwen3.8-27B-Splash",
  "maxMemory": "auto",
  "maxContext": "auto",
  "apiKey": "",
  "allowedHost": "",
  "noWebUI": false,
  "loginItem": false,
  "autoStartOnLaunch": false,
  "showModelName": true
}
```

Every field is editable from the menu; the file can also be hand-edited. Decoding is field-by-field
with fallbacks, so an older config file never invalidates the whole thing.

Runtime files live in the same directory: `splash.pid`, `splash.log`, `splash.err`.

## Project layout

```
SplashBar/
├── main.swift        # Menu bar UI, state machine, process control, CLI
├── makeicons.swift   # CoreGraphics icon generator → PNGs + AppIcon.iconset
├── build.sh          # One-shot build script
├── Info.plist        # Bundle metadata
├── preview/          # Icon and state previews
└── README.md
```

## Notes for anyone porting this

Three things cost real debugging time:

1. **`launchctl` is unusable on some machines.** `launchctl bootstrap gui/$UID` returns
   `Bootstrap failed: 5: Input/output error` here even for a minimal plist. The fix is to spawn with
   `posix_spawn` + `POSIX_SPAWN_SETSID` and use `SMAppService` for the login item.
2. **Detecting a stopped process.** `/bin/ps` fails with `operation not permitted` under the sandbox.
   Use `libproc`: `proc_pidinfo(pid, PROC_PIDTBSDINFO, ...)` and compare `pbi_status` against
   `SSTOP`, which is **4**, not 3 — 3 is `SSLEEP`.
3. **Menu items that refuse to grey out.** `NSMenu.autoenablesItems` defaults to `true`, which
   overrides a manually set `isEnabled` with its own "does the target respond to this action?" check.
   Set `autoenablesItems = false` (including on submenus).

Splash only loads its own packaged `splash-packed-q4` / `splash-packed-q4-moe` bundles — it will not
load raw HuggingFace or GGUF weights.

## License

MIT
