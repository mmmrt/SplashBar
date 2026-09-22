# Splash-MLX

A menu bar control panel for local inference on Apple silicon. It drives two engines:

- **[Splash](https://github.com/incoai/splash)** — Inco AI's native engine
- **[mlx-serve](https://github.com/ddalcu/mlx-serve)** — a native Zig server for MLX models

Pick either one and Splash-MLX starts, stops and configures it for you. There is no window and no
Dock icon — it lives entirely in the menu bar.

**The engines do all the real work.** This is only a front end: everything that actually runs a
model belongs to the projects above.

## What it does

Click the icon and a menu pops up. The menu changes to match whichever engine you picked.

- **Engine** — pick Splash or mlx-serve. Only one can run at a time. Switch and the other one stops.
- **Model** — pick the model to load. The list comes from the engine you picked, so switch engines
  and the list switches too. Models somewhere weird? Point at the folder yourself in *Settings →
  Model folder*.
- **Start / Pause / Stop / Restart** — greyed out until they actually do something. Pause freezes it:
  memory stays held, CPU goes quiet.
- **Settings** — shows up once it is running. Each engine has its own options, and an option only
  appears if that engine really understands it — so you cannot pick something that breaks the start.

While it runs you can watch how fast it is going, how much memory it is using, and the address to
point your apps at.

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
