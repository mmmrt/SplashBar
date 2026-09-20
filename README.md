# SplashBar

A menu bar remote control for [Splash](https://github.com/incoai/splash), the local inference engine
for Apple silicon.

Splash does all the real work — this is just a small menu bar front-end so you don't have to run
`splash serve` in a terminal and babysit it. Click the icon to start, pause, resume, stop or restart;
see tok/s, draft acceptance rate and memory usage at a glance; check which engine version is actually
running; and change the model, `--max-memory`, `--max-context`, `--port` or API key without
remembering any flags.

**All credit goes to [Splash](https://github.com/incoai/splash).** This is only a thin wrapper around
it — everything that actually runs the model is theirs.

## Install

```bash
git clone https://github.com/mmmrt/SplashBar.git
cd SplashBar
./build.sh
open ~/Applications/SplashBar.app
```

Needs Xcode Command Line Tools (`xcrun swiftc`, `iconutil`) and Apple Silicon / macOS 13+.
No window, no Dock icon — it lives in the menu bar.

## License

MIT
