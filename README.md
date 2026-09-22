# Splash-MLX

A menu bar control panel for local inference on Apple silicon. It drives two engines:

- **[Splash](https://github.com/incoai/splash)** — Inco AI's native engine
- **[mlx-serve](https://github.com/ddalcu/mlx-serve)** — a native Zig server for MLX models

Pick either one and Splash-MLX starts, stops and configures it for you. There is no window and no
Dock icon — it lives entirely in the menu bar.

**The engines do all the real work.** This is only a front end: everything that actually runs a
model belongs to the projects above.

## What it does

Click the icon; the menu adapts to the engine you selected.

- **Engine** — switch between Splash and mlx-serve. They are mutually exclusive: only one runs at a
  time, and switching stops the running one first.
- **Model** — the list is refreshed from whichever engine is selected. mlx-serve reports its library
  through `mlx-serve list`; Splash has no such command, so its models are found by scanning Splash's
  own model folder plus the Hugging Face cache. If your models live somewhere unusual, point at them
  by hand in *Settings → Model folder*.
- **Start / Pause / Stop / Restart** — Pause freezes the process with `SIGSTOP`, so memory stays held
  but the CPU goes quiet. Buttons grey out when they do not apply.
- **Settings** — appears once the engine is running. Options differ per engine, and each one is only
  offered if that engine actually accepts it: Splash-MLX reads `--help` from the engine and greys out
  anything it does not recognise, so a setting can never make the service fail to start.

While it is running you also get live tok/s, draft acceptance rate, memory use, time to first token
and the context limit, plus the resolved engine version and API base URL.

## Install

```bash
git clone https://github.com/mmmrt/splash-mlx.git
cd splash-mlx
./build.sh
open ~/Applications/SplashMLX.app
```

Needs Xcode Command Line Tools (`xcrun swiftc`, `iconutil`), Apple Silicon and macOS 13+.

You also need at least one of the engines:

```bash
brew install incoai/tap/splash

brew tap ddalcu/mlx-serve https://github.com/ddalcu/mlx-serve && brew install mlx-serve
```

## Configuration

Settings live in `~/Library/Application Support/SplashMLX/config.json`, with one section per engine,
so switching back and forth keeps each engine's model, port and flags as you left them.

## License

MIT
