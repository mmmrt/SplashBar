# SplashBar

A small macOS menu bar app for managing a local [Splash](https://splash.inco.ai) inference server —
start, pause, resume, stop, restart — without opening a terminal.

Pure Swift + AppKit. No Xcode project, no dependencies. Requires Apple Silicon / macOS 13+.

## Features

- **Three-state menu bar icon** — running / paused / stopped
- **Start, Pause, Resume, Stop, Restart** — pause freezes the process with `SIGSTOP` so memory stays
  loaded and resuming is instant instead of a ~12 s model reload
- **Live stats** — decode speed, draft acceptance rate, memory usage, TTFT
- **Serve parameters in the menu** — model, `--max-memory`, `--max-context`, API key, `--allowed-host`, `--no-webui`
- **Takes over** a `splash serve` process you started yourself in a terminal
- **Menu items grey out** by state, so you can't start a second server or pause something idle
- **Login item**, and quitting asks for confirmation before stopping the server

## Install

```bash
git clone https://github.com/mmmrt/SplashBar.git
cd SplashBar
./build.sh
open ~/Applications/SplashBar.app
```

Needs Xcode Command Line Tools (`xcrun swiftc`, `iconutil`).
No window, no Dock icon — it lives in the menu bar.

## Usage

Click the icon. The menu shows live stats on top, controls in the middle, and serve settings below.

| State | Start | Pause | Stop | Restart |
|---|---|---|---|---|
| Stopped | ✅ | ── | ── | ── |
| Running | ── | ✅ | ✅ | ✅ |
| Paused | ✅ (Resume) | ── | ✅ | ✅ |

Config lives at `~/Library/Application Support/SplashBar/config.json` and can be edited from the menu
or by hand.

The binary also works as a CLI:

```bash
~/Applications/SplashBar.app/Contents/MacOS/SplashBar --status   # or --start --pause --resume --stop --restart --takeover --help
```

## Layout

```
main.swift        menu bar UI, state machine, process control, CLI
makeicons.swift   CoreGraphics icon generator
build.sh          one-shot build
Info.plist        bundle metadata
preview/          icon previews
```

## License

MIT
