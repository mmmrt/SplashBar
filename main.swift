//  SplashBar — macOS 菜单栏常驻控制器，用于管理 Splash 推理服务的启动参数与启停。
//  纯 AppKit 实现（无窗口、无 Dock 图标）。
//  服务以独立会话（setsid）子进程方式拉起，菜单栏 App 退出后服务继续运行。
//  登录自启通过 SMAppService 注册本 App 实现（不走 launchd，避开本机 bootstrap 被拒的问题）。

import AppKit
import Foundation
import ServiceManagement

// MARK: - 常量与路径

private let kSplashBin = "/opt/homebrew/bin/splash"

// Splash 1.0.1 起支持 `--port`，可以有多个实例跑在不同端口上，
// 所以端口不能再是编译期常量。App 启动和 CLI 入口统一先 syncPort(cfg.port)，
// 让下面这些静态方法（lsof / curl / 拼 URL）探到正确的端口。
var activePort: String = "8000"
private var baseURL: String { "http://127.0.0.1:\(activePort)" }

func syncPort(_ p: String) { activePort = p.isEmpty ? "8000" : p }

// libproc 常量（直接给字面量，避免依赖 C 宏是否被 Swift 桥接）
private let kProcPidTBSDInfo: Int32 = 3   // PROC_PIDTBSDINFO（实测返回 136 = sizeof(proc_bsdinfo)）
// 纯信息行（不可点）的标记，--dump-menu 靠它区分"信息行"和"置灰的功能项"
private let kInfoTag = 99
// sys/proc.h: SIDL=1 SRUN=2 SSLEEP=3 SSTOP=4 SZOMB=5
// 注意 SSTOP 是 4，写成 3(SSLEEP) 会导致暂停永远检测不到
private let kSSTOP: UInt32 = 4

private func homeURL() -> URL { FileManager.default.homeDirectoryForCurrentUser }

private var appSupportDir: URL { homeURL().appendingPathComponent("Library/Application Support/SplashBar") }
private var configURL:     URL { appSupportDir.appendingPathComponent("config.json") }
private var pidURL:        URL { appSupportDir.appendingPathComponent("splash.pid") }
private var logOutPath: String { homeURL().appendingPathComponent("Library/Logs/splashbar.out.log").path }
private var logErrPath: String { homeURL().appendingPathComponent("Library/Logs/splashbar.err.log").path }
private var splashModelsDir: URL {
    homeURL().appendingPathComponent("Library/Application Support/Splash/models")
}

// MARK: - 配置

final class Config: Codable {
    var model: String = "incoai/Qwen3.8-27B-Splash"
    var maxMemory: String = "auto"
    var maxContext: String = "auto"
    var apiKey: String = ""
    var allowedHost: String = ""
    /// HTTP 端口。Splash 1.0.1 起支持 --port，改这里就能跑多个实例
    var port: String = "8000"
    /// --max-request-size。留空=不传该参数，用 Splash 默认（1.0.1 起为 128M）
    var maxRequestSize: String = ""
    var noWebUI: Bool = false
    var loginItem: Bool = false
    var autoStartOnLaunch: Bool = false
    /// 菜单栏图标右侧是否显示模型名
    var showModelName: Bool = true

    /// 手写解码：任一字段缺失（老版本配置文件）都退回默认值，不整体丢弃配置
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model             = (try? c.decode(String.self, forKey: .model)) ?? model
        maxMemory         = (try? c.decode(String.self, forKey: .maxMemory)) ?? maxMemory
        maxContext        = (try? c.decode(String.self, forKey: .maxContext)) ?? maxContext
        apiKey            = (try? c.decode(String.self, forKey: .apiKey)) ?? apiKey
        allowedHost       = (try? c.decode(String.self, forKey: .allowedHost)) ?? allowedHost
        port              = (try? c.decode(String.self, forKey: .port)) ?? port
        maxRequestSize    = (try? c.decode(String.self, forKey: .maxRequestSize)) ?? maxRequestSize
        noWebUI           = (try? c.decode(Bool.self, forKey: .noWebUI)) ?? noWebUI
        loginItem         = (try? c.decode(Bool.self, forKey: .loginItem)) ?? loginItem
        autoStartOnLaunch = (try? c.decode(Bool.self, forKey: .autoStartOnLaunch)) ?? autoStartOnLaunch
        showModelName     = (try? c.decode(Bool.self, forKey: .showModelName)) ?? showModelName
    }

    static func load() -> Config {
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        return Config()
    }

    func save() {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: configURL) }
    }

    var serveArguments: [String] {
        var a = ["serve", "--model", model, "--max-memory", maxMemory, "--max-context", maxContext]
        // 端口只在非默认时才显式传 --port，这样旧的 Splash（1.0，无此参数）也能照常跑
        if !port.isEmpty && port != "8000" { a += ["--port", port] }
        if !maxRequestSize.isEmpty { a += ["--max-request-size", maxRequestSize] }
        if !allowedHost.isEmpty { a += ["--allowed-host", allowedHost] }
        if noWebUI { a += ["--no-webui"] }
        return a
    }
}

// MARK: - 工具

@discardableResult
private func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return (-1, "", error.localizedDescription) }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

/// 以新会话（setsid）拉起进程：脱离本 App 的进程组，App 退出后仍存活，
/// 且 pgid == pid，便于整组（server.py + engine）一次性 kill。
private func spawnDetached(_ argv: [String], env: [String: String]) -> pid_t? {
    var pid: pid_t = 0

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 1, logOutPath,
                                     O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_addopen(&actions, 2, logErrPath,
                                     O_WRONLY | O_CREAT | O_APPEND, 0o644)

    let argvPtr = argv.map { strdup($0) } + [nil]
    let envPtr  = env.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]

    let rc = posix_spawn(&pid, argv[0], &actions, &attr, argvPtr, envPtr)
    for p in argvPtr { free(p) }
    for p in envPtr  { free(p) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    return rc == 0 ? pid : nil
}

// MARK: - 服务状态

struct Status {
    var up = false
    var maxContext = 0
    var tps = 0.0
    var accept = 0.0
    var ttftP50 = 0.0
    var memoryPressure = ""
    var residentGB = 0.0
    var deviceName = ""
}

// MARK: - 服务控制器

enum Service {

    /// 版本探测的两个小缓存：运行中版本按 pid 缓存，已安装版本只查一次
    private static var versionCache: (pid: pid_t, version: String?)?
    private static var installedCache: String?
    private static var installedQueried = false

    static var recordedPID: pid_t? {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .newlines),
              let p = pid_t(s) else { return nil }
        return p
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// 本 App 托管中（pid 文件有效且进程存活）
    static var managed: Bool {
        guard let p = recordedPID else { return false }
        return isAlive(p)
    }

    /// 是否处于暂停（SIGSTOP 冻结）状态
    /// 走 libproc 直接读 proc_bsdinfo.pbi_status，不 spawn /bin/ps —— 外部命令在受限
    /// 执行环境里可能被程序策略拒绝（实测 ps 会 "operation not permitted"），那样会误判成未暂停。
    static var paused: Bool {
        guard let p = recordedPID, isAlive(p) else { return false }
        var info = proc_bsdinfo()
        let n = proc_pidinfo(p, kProcPidTBSDInfo, 0,
                             &info, Int32(MemoryLayout<proc_bsdinfo>.stride))
        if n == Int32(MemoryLayout<proc_bsdinfo>.stride) {
            return info.pbi_status == kSSTOP
        }
        // 极少数情况下 libproc 读不到，退回解析 ps
        let r = run("/bin/ps", ["-o", "stat=", "-p", "\(p)"])
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("T")
    }

    /// 暂停：向整个进程组发 SIGSTOP（进程冻结，显存/内存仍占用，但不再吃 CPU）
    static func pause() -> String {
        guard let p = recordedPID, isAlive(p) else { return "no managed process to pause" }
        if paused { return "already paused" }
        kill(-p, SIGSTOP)
        kill(p, SIGSTOP)
        return "paused pid=\(p)"
    }

    /// 继续：SIGCONT
    static func resume() -> String {
        guard let p = recordedPID, isAlive(p) else { return "no managed process to resume" }
        kill(-p, SIGCONT)
        kill(p, SIGCONT)
        return "resumed pid=\(p)"
    }

    /// 占用当前配置端口的 pid 列表
    static func pidsOnPort() -> [pid_t] {
        let r = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(activePort)", "-sTCP:LISTEN", "-t"])
        return r.out.split(separator: "\n").compactMap { pid_t($0) }
    }

    // MARK: 版本探测

    /// 「正在运行」的版本。`/status` 不提供版本字段（schema 5 里只有 schema_version），
    /// 所以从进程可执行文件路径反推：托管进程跑的是
    /// `…/Cellar/splash/<ver>/libexec/python/bin/python3.13`（brew 装）
    /// 或 `…/splash-<ver>-arm64-macos26/…`（release 包解包后手动跑）。
    static func runningVersion() -> String? {
        guard let pid = recordedPID, isAlive(pid) else { return nil }
        if let cached = versionCache, cached.pid == pid { return cached.version }
        let r = run("/usr/sbin/lsof", ["-p", String(pid), "-a", "-d", "txt", "-Fn"])
        var found: String?
        for line in r.out.split(separator: "\n") where line.hasPrefix("n") {
            if let v = versionFromPath(String(line.dropFirst())) { found = v; break }
        }
        versionCache = (pid, found)
        return found
    }

    /// 从可执行文件路径里抽版本号。
    /// 逐个候选扫描而不是只取第一处匹配 —— 因为解包目录常被放在名字里也带 "splash-" 的
    /// 父目录下（如 /tmp/splash-test/v10/splash-1.0-arm64-macos26/…），只取第一处会解析失败。
    static func versionFromPath(_ path: String) -> String? {
        var idx = path.startIndex
        while let r = path.range(of: "/Cellar/splash/", range: idx..<path.endIndex) {
            let v = path[r.upperBound...].prefix { $0 != "/" }
            if v.first?.isNumber == true { return String(v) }
            idx = r.upperBound
        }
        idx = path.startIndex
        while let r = path.range(of: "/splash-", range: idx..<path.endIndex) {
            let v = path[r.upperBound...].prefix { $0.isNumber || $0 == "." }
            if v.contains(where: \.isNumber) { return String(v) }
            idx = r.upperBound
        }
        return nil
    }

    /// 「已安装」的版本（`splash --version` → "Splash 1.0.1"）。
    /// 会拉起一个 Python，耗时约 0.3–1s，所以只查一次然后缓存。
    static func installedVersion() -> String? {
        if installedQueried { return installedCache }
        installedQueried = true
        let r = run(kSplashBin, ["--version"])
        let raw = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0, let last = raw.split(separator: " ").last,
           last.contains(where: \.isNumber) {
            installedCache = String(last)
        }
        return installedCache
    }

    static func start(cfg: Config) -> String {
        if managed { return "already running (pid \(recordedPID!))" }
        // 端口已被别人占着时拒绝启动：否则会 spawn 出第二个进程、绑定 8000 失败，
        // pid 文件却被新 pid 覆盖，造成"显示托管中、实际服务是死的"的错乱状态。
        if status().up {
            let who = pidsOnPort().map(String.init).joined(separator: ",")
            return "refusing to start: port \(activePort) is held by an external process (pid \(who)). Stop it first, or use --takeover"
        }
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: logErrPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logOutPath, contents: nil)
        FileManager.default.createFile(atPath: logErrPath, contents: nil)

        var env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                   "HOME": homeURL().path]
        if !cfg.apiKey.isEmpty { env["SPLASH_API_KEY"] = cfg.apiKey }

        let argv = [kSplashBin] + cfg.serveArguments
        guard let pid = spawnDetached(argv, env: env) else {
            return "start failed: posix_spawn returned \(errno)"
        }
        try? String(pid).write(to: pidURL, atomically: true, encoding: .utf8)
        return "started pid=\(pid)"
    }

    static func stop() -> String {
        var killed: [pid_t] = []
        if let pid = recordedPID {
            kill(-pid, SIGTERM)          // 整组：server.py + serve-native engine
            kill(pid, SIGTERM)
            killed.append(pid)
        }
        Thread.sleep(forTimeInterval: 2.0)
        if let pid = recordedPID, isAlive(pid) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        for p in pidsOnPort() where !killed.contains(p) {
            kill(p, SIGTERM)
            killed.append(p)
        }
        Thread.sleep(forTimeInterval: 1.0)
        for p in pidsOnPort() { kill(p, SIGKILL) }
        try? FileManager.default.removeItem(at: pidURL)
        return killed.isEmpty ? "nothing to stop" : "stopped pid=\(killed.map(String.init).joined(separator: ","))"
    }

    static func restart(cfg: Config) -> String {
        _ = stop()
        return start(cfg: cfg)
    }

    /// 状态探测。已暂停（进程冻结）时直接短路，避免每次轮询都等 curl 超时。
    static func status() -> Status {
        var s = Status()
        if paused { return s }
        let r = run("/usr/bin/curl", ["-s", "--noproxy", "*", "--max-time", "2",
                                      baseURL + "/status"])
        guard r.status == 0,
              let data = r.out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return s
        }
        s.up = true
        s.maxContext = (obj["maximum_context_tokens"] as? Int) ?? 0
        s.memoryPressure = (obj["memory_pressure"] as? String) ?? ""
        if let m = obj["metrics"] as? [String: Any] {
            if let d = m["decode_tokens_per_second"] as? Double { s.tps = d }
            if let d = m["draft_acceptance_rate"] as? Double { s.accept = d }
            if let t = m["ttft_ms"] as? [String: Any], let p = t["p50"] as? Double { s.ttftP50 = p }
        }
        if let mp = obj["memory_plan"] as? [String: Any],
           let dev = mp["device"] as? [String: Any],
           let n = dev["device_name"] as? String { s.deviceName = n }
        if let ma = obj["memory_actual"] as? [String: Any],
           let b = ma["current_bytes"] as? Double { s.residentGB = b / 1_073_741_824.0 }
        return s
    }
}

// MARK: - 菜单状态机（纯函数，可单独验证）

/// 一次探测的快照。四个布尔量决定了整个菜单的可用性。
struct Snapshot {
    var served = false    // HTTP /status 有响应
    var owned = false     // pid 文件有效且进程存活（本 App 托管）
    var paused = false    // 托管进程处于 SIGSTOP 冻结
    var starting = false  // 刚刚下发过启动命令的短暂过渡态

    /// 端口在响应，但不是我们管的（例如手工在终端跑的 splash）
    var isExternal: Bool { served && !owned }
    /// 真正在提供服务
    var isRunning: Bool { served && !paused }
    /// 进程已起、HTTP 还没就绪（Splash 加载模型约 12s）
    var isLoading: Bool { owned && !served && !paused }
}

/// 菜单项可用性规则。写成纯函数，便于 `--states` 打印全量真值表核对。
struct MenuPolicy {
    let s: Snapshot

    /// 启动（暂停态下语义为"继续"）
    /// 关键：端口已被占用（served）时一律不可启动，否则会 spawn 第二个进程、
    /// 绑定 8000 失败，pid 文件却被新 pid 覆盖，造成"显示托管中、实际是死的"错乱。
    var canStart: Bool { !s.starting && !s.served && (!s.owned || s.paused) }

    /// 暂停：只有真正在跑的托管进程才能暂停
    var canPause: Bool { s.owned && s.isRunning && !s.starting }

    /// 停止：有托管进程，或端口被外部进程占用（此时"停止"即清掉外部进程）
    var canStop: Bool { (s.owned || s.isExternal) && !s.starting }

    /// 重启：同停止。外部进程时等价于"接管后重启"
    var canRestart: Bool { (s.owned || s.isExternal) && !s.starting }

    /// 接管：仅在外部进程占用端口时显示
    var canTakeOver: Bool { s.isExternal && !s.starting }

    /// 打开 Web UI
    var canOpenUI: Bool { s.isRunning }
}

// MARK: - App 委托

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    var statusItem: NSStatusItem!
    var cfg = Config.load()
    var st = Status()
    var timer: Timer?
    var starting = false

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        syncPort(cfg.port)          // 必须在任何 Service 探测之前，否则会探到默认端口

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        rebuildMenu()
        refresh()

        if cfg.autoStartOnLaunch && !Service.managed && !Service.status().up {
            starting = true
            DispatchQueue.global().async { [weak self] in
                guard let self = self else { return }
                _ = Service.start(cfg: self.cfg)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.starting = false
                    self.refresh()
                }
            }
            rebuildMenu()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationWillTerminate(_ aNotification: Notification) { timer?.invalidate() }

    /// 状态探测放到后台：curl 最长可能阻塞 2 秒，放主线程会让菜单卡顿
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = Service.status()
            DispatchQueue.main.async {
                self?.st = s
                self?.rebuildMenu()
            }
        }
    }

    // MARK: 菜单

    /// 把构建好的菜单挂到状态栏
    func rebuildMenu() {
        statusItem.menu = buildMenu()
        applyStatusButton()
    }

    /// 纯构建：不碰 statusItem，便于 CLI 里单独 dump 校验
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // 必须关掉自动启用！NSMenu.autoenablesItems 默认 true，AppKit 会忽略我们
        // 手写的 isEnabled，改按"target 是否响应 action"判定；而本类实现了全部
        // 四个 action，于是启动/暂停/停止/重启会永远点亮（已实测复现）。
        menu.autoenablesItems = false

        // 一次探测，统一快照；所有可用性判定都走 MenuPolicy
        let owned = Service.managed
        let isPaused = Service.paused
        let snap = Snapshot(served: st.up, owned: owned, paused: isPaused, starting: starting)
        let policy = MenuPolicy(s: snap)

        let external = snap.isExternal
        let running = snap.isRunning

        // ── 状态区：压到 4 行以内（原来是 7 行）
        let runVer = Service.runningVersion()
        let instVer = Service.installedVersion()
        menu.addItem(disabled("Splash \(runVer ?? instVer ?? "?")  ·  \(stateLabel())"))
        if running {
            menu.addItem(disabled(String(format: "%.1f tok/s · accept %.1f%% · memory %.1f GB",
                                         st.tps, st.accept * 100, st.residentGB)))
        }
        menu.addItem(disabled("\(modelShortName())  ·  \(baseURL.replacingOccurrences(of: "http://", with: ""))"))
        if running {
            menu.addItem(disabled(String(format: "TTFT %.0f ms · limit %dK", st.ttftP50, st.maxContext / 1024)))
        }
        if let r = runVer, let i = instVer, r != i {
            menu.addItem(disabled("⚠️ running \(r) ≠ installed \(i) — restart to switch"))
        }
        if external { menu.addItem(disabled("⚠️ port held by an external process, not managed by SplashBar")) }
        if starting { menu.addItem(disabled("⏳ loading model…")) }
        menu.addItem(.separator())

        // 启动：运行中 / 端口被占用时置灰；暂停时充当"继续"
        let startItem = NSMenuItem(title: isPaused ? "▶  Resume" : "▶  Start",
                                   action: #selector(startService), keyEquivalent: "s")
        startItem.target = self
        startItem.isEnabled = policy.canStart
        menu.addItem(startItem)

        // 暂停：仅"真正在跑的托管进程"可用；暂停中 / 启动中 / 已停止均置灰
        let pauseItem = NSMenuItem(title: "⏸  Pause", action: #selector(pauseService), keyEquivalent: "p")
        pauseItem.target = self
        pauseItem.isEnabled = policy.canPause
        menu.addItem(pauseItem)

        // 停止：有托管进程或外部进程时可用；已停止置灰
        let stopItem = NSMenuItem(title: external ? "■  Stop (external)" : "■  Stop",
                                  action: #selector(stopService), keyEquivalent: "x")
        stopItem.target = self
        stopItem.isEnabled = policy.canStop
        menu.addItem(stopItem)

        let restartItem = NSMenuItem(title: "⟳  Restart", action: #selector(restartService), keyEquivalent: "r")
        restartItem.target = self
        restartItem.isEnabled = policy.canRestart
        menu.addItem(restartItem)

        // 端口被外部进程占用时，给一个显式接管入口（v1.0 有，v1.1 重写菜单时漏掉了，现恢复）
        if policy.canTakeOver {
            let take = NSMenuItem(title: "⇪  Take over as managed",
                                  action: #selector(takeOver), keyEquivalent: "")
            take.target = self
            menu.addItem(take)
        }
        menu.addItem(.separator())

        // ── 参数设置：8 个参数子菜单收进一个入口（原来平铺占 8 行）
        menu.addItem(submenuItem("Settings", items: [
            submenuItem("Model", items: modelItems()),
            submenuItem("Max memory  --max-memory", items: choiceItems(
                current: cfg.maxMemory,
                options: [("auto", "auto (≈107 GB, M5 Max limit)"),
                          ("24G", "24G"), ("32G", "32G"), ("48G", "48G"),
                          ("64G", "64G"), ("96G", "96G")],
                customLabel: "Custom… (e.g. 28G)", tag: 1)),
            submenuItem("Context  --max-context", items: choiceItems(
                current: cfg.maxContext,
                options: [("auto", "auto (262144 = 256K)"),
                          ("32K", "32K"), ("64K", "64K"), ("128K", "128K"), ("256K", "256K")],
                customLabel: "Custom… (e.g. 100K)", tag: 2)),
            submenuItem("Port  --port", items: choiceItems(
                current: cfg.port,
                options: [("8000", "8000 (Splash default)"),
                          ("8080", "8080"), ("8123", "8123"), ("9000", "9000")],
                customLabel: "Custom… (e.g. 7000)", tag: 3)),
            submenuItem("Max request size  --max-request-size", items: choiceItems(
                current: cfg.maxRequestSize,
                options: [("", "128M (Splash 1.0.1 default — flag omitted)"),
                          ("64M", "64M"), ("256M", "256M"), ("512M", "512M"), ("1G", "1G")],
                customLabel: "Custom… (e.g. 32M)", tag: 4)),
            submenuItem("API Key  --api-key", items: apiKeyItems()),
            submenuItem("Allowed host  --allowed-host", items: hostItems()),
            submenuItem("Web UI  --no-webui", items: webUIItems()),
        ]))

        // ── 打开：5 个入口收进一个子菜单（原来平铺占 5 行）
        let openUI = NSMenuItem(title: "Open Web UI in browser", action: #selector(openWebUI), keyEquivalent: "o")
        openUI.target = self
        openUI.isEnabled = policy.canOpenUI && !cfg.noWebUI
        let copyURL = NSMenuItem(title: "Copy API base URL", action: #selector(copyBaseURL), keyEquivalent: "c")
        copyURL.target = self
        var openItems: [NSMenuItem] = [openUI, copyURL, .separator()]
        for (title, sel) in [("View runtime log", #selector(openLogs)),
                             ("Open models folder", #selector(openModelDir)),
                             ("Open config folder", #selector(openConfigDir))] as [(String, Selector)] {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            openItems.append(it)
        }
        menu.addItem(submenuItem("Open", items: openItems))

        // ── 偏好与关于：开关 + 关于收进一个子菜单（原来平铺占 3 行）
        let showName = NSMenuItem(title: "Show model name in menu bar", action: #selector(toggleModelName), keyEquivalent: "")
        showName.target = self
        showName.state = cfg.showModelName ? .on : .off

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = cfg.loginItem ? .on : .off

        let about = NSMenuItem(title: "About SplashBar", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(submenuItem("Preferences & About", items: [showName, login, .separator(), about]))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SplashBar (stops the service)",
                              action: #selector(confirmQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// 状态短标签（和版本号拼在同一行，所以不重复图标之外的信息）
    private func stateLabel() -> String {
        if Service.paused { return "paused (frozen, memory still held)" }
        if st.up { return Service.managed ? "running (managed)" : "running (external)" }
        if Service.managed || starting { return "starting (waiting for model)" }
        return "stopped"
    }

    /// 从 App 包 Resources 里按 @3x → @2x → 1x 顺序取菜单栏图标
    private func menuBarIcon() -> NSImage? {
        let name: String
        if Service.paused { name = "menubar_paused" }
        else if st.up { name = "menubar_running" }
        else if Service.managed || starting { name = "menubar_paused" }   // 启动中：琥珀色过渡态
        else { name = "menubar_stopped" }

        let res = Bundle.main.resourcePath ?? ""
        for suffix in ["@3x", "@2x", ""] {
            let path = "\(res)/\(name)\(suffix).png"
            if FileManager.default.fileExists(atPath: path),
               let img = NSImage(contentsOfFile: path) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = false
                return img
            }
        }
        return nil
    }

    private func modelShortName() -> String {
        let short = cfg.model.split(separator: "/").last.map(String.init) ?? cfg.model
        return short.replacingOccurrences(of: "-Splash", with: "")
    }

    private func applyStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = menuBarIcon()
        button.imagePosition = cfg.showModelName ? .imageLeading : .imageOnly
        button.title = cfg.showModelName ? " " + modelShortName() : ""
        button.toolTip = "SplashBar — \(cfg.model)"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        it.tag = kInfoTag          // 打标，方便 --dump-menu 跳过纯信息行
        return it
    }

    private func submenuItem(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false      // 同上：保证子菜单里的自定义置灰生效
        for i in items { sub.addItem(i) }
        it.submenu = sub
        return it
    }

    private func choiceItems(current: String, options: [(String, String)],
                             customLabel: String, tag: Int) -> [NSMenuItem] {
        var items = options.map { value, label -> NSMenuItem in
            let it = NSMenuItem(title: label, action: #selector(pickValue(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
            it.representedObject = value
            it.state = (value == current) ? .on : .off
            return it
        }
        items.append(.separator())
        let custom = NSMenuItem(title: customLabel, action: #selector(pickCustom(_:)), keyEquivalent: "")
        custom.target = self
        custom.tag = tag
        items.append(custom)
        return items
    }

    private func modelItems() -> [NSMenuItem] {
        var items = installedModels().map { m -> NSMenuItem in
            let it = NSMenuItem(title: m, action: #selector(pickModel(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m
            it.state = (m == cfg.model) ? .on : .off
            return it
        }
        items.append(.separator())
        let custom = NSMenuItem(title: "Custom owner/repo…", action: #selector(pickCustomModel), keyEquivalent: "")
        custom.target = self
        items.append(custom)
        return items
    }

    private func apiKeyItems() -> [NSMenuItem] {
        let cur = cfg.apiKey.isEmpty ? "not set (no auth)" : "set (\(cfg.apiKey.count) chars)"
        let items = [disabled("Current: \(cur)"), NSMenuItem.separator()]
        let set = NSMenuItem(title: "Set / change…", action: #selector(setAPIKey), keyEquivalent: "")
        set.target = self
        let clear = NSMenuItem(title: "Clear", action: #selector(clearAPIKey), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !cfg.apiKey.isEmpty
        return items + [set, clear]
    }

    private func hostItems() -> [NSMenuItem] {
        let only = NSMenuItem(title: "Localhost only (127.0.0.1)", action: #selector(clearHost), keyEquivalent: "")
        only.target = self
        only.state = cfg.allowedHost.isEmpty ? .on : .off
        var items = [only, NSMenuItem.separator()]
        if !cfg.allowedHost.isEmpty { items.append(disabled("Current: \(cfg.allowedHost)")) }
        let set = NSMenuItem(title: "Allow LAN access…", action: #selector(setHost), keyEquivalent: "")
        set.target = self
        items.append(set)
        return items
    }

    private func webUIItems() -> [NSMenuItem] {
        let on = NSMenuItem(title: "On (default)", action: #selector(setWebUIOn), keyEquivalent: "")
        on.target = self
        on.state = cfg.noWebUI ? .off : .on
        let off = NSMenuItem(title: "Off --no-webui", action: #selector(setWebUIOff), keyEquivalent: "")
        off.target = self
        off.state = cfg.noWebUI ? .on : .off
        return [on, off]
    }

    private func installedModels() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        if let owners = try? fm.contentsOfDirectory(atPath: splashModelsDir.path) {
            for owner in owners where !owner.hasPrefix(".") {
                let dir = splashModelsDir.appendingPathComponent(owner)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
                    for name in names where !name.hasPrefix(".") { out.append("\(owner)/\(name)") }
                }
            }
        }
        if out.isEmpty { out = ["incoai/Qwen3.8-27B-Splash", "incoai/Qwen3.6-35B-A3B-Splash"] }
        if !out.contains(cfg.model) { out.append(cfg.model) }
        return out.sorted()
    }

    // MARK: 动作

    @objc func openWebUI() { NSWorkspace.shared.open(URL(string: baseURL)!) }

    @objc func copyBaseURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(baseURL + "/v1", forType: .string)
    }

    @objc func startService() {
        // 暂停态下"启动"即"继续"
        if Service.paused {
            print("[SplashBar] \(Service.resume())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
            return
        }
        starting = true
        rebuildMenu()
        let cfgNow = cfg
        DispatchQueue.global().async { [weak self] in
            let msg = Service.start(cfg: cfgNow)
            print("[SplashBar] \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.starting = false
                self?.refresh()
            }
        }
    }

    @objc func pauseService() {
        print("[SplashBar] \(Service.pause())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    /// 端口被外部进程占用时：先杀掉它，再由本 App 重新拉起，纳入托管
    @objc func takeOver() {
        starting = true
        rebuildMenu()
        let cfgNow = cfg
        DispatchQueue.global().async { [weak self] in
            let killed = Service.pidsOnPort()
            for p in killed { kill(p, SIGTERM) }
            Thread.sleep(forTimeInterval: 1.5)
            for p in Service.pidsOnPort() { kill(p, SIGKILL) }
            try? FileManager.default.removeItem(at: pidURL)
            let msg = Service.start(cfg: cfgNow)
            print("[SplashBar] take-over: killed external process(es) [\(killed.map(String.init).joined(separator: ","))]; \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.starting = false
                self?.refresh()
            }
        }
    }

    @objc func confirmQuit() {
        let a = NSAlert()
        a.messageText = "Quit SplashBar?"
        a.informativeText = """
        Quitting will also stop the inference service:
        \(cfg.model)

        Reopen SplashBar to start it again.
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "Quit and stop service")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        print("[SplashBar] quit: \(Service.stop())")
        NSApp.terminate(nil)
    }

    @objc func toggleModelName() {
        cfg.showModelName.toggle()
        cfg.save()
        applyStatusButton()
    }

    @objc func stopService() {
        DispatchQueue.global().async { [weak self] in
            let msg = Service.stop()
            print("[SplashBar] \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refresh() }
        }
    }

    @objc func restartService() {
        starting = true
        rebuildMenu()
        let cfgNow = cfg
        DispatchQueue.global().async { [weak self] in
            let msg = Service.restart(cfg: cfgNow)
            print("[SplashBar] \(msg)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.starting = false
                self?.refresh()
            }
        }
    }

    @objc func pickModel(_ sender: NSMenuItem) {
        guard let m = sender.representedObject as? String else { return }
        cfg.model = m; cfg.save(); askRestart("Model switched to \(m)")
    }

    @objc func pickCustomModel() {
        guard let v = askString(title: "Custom model",
                                message: "Hugging Face repository, in owner/repo form",
                                defaultValue: cfg.model), !v.isEmpty else { return }
        cfg.model = v; cfg.save(); askRestart("Model switched to \(v)")
    }

    @objc func pickValue(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        switch sender.tag {
        case 1:  cfg.maxMemory = v
        case 2:  cfg.maxContext = v
        case 3:  cfg.port = v
        case 4:  cfg.maxRequestSize = v
        default: return
        }
        cfg.save()
        syncPort(cfg.port)          // 端口一改，探测用的 activePort 必须立刻跟上
        askRestart("Setting updated: \(v.isEmpty ? "default" : v)")
    }

    @objc func pickCustom(_ sender: NSMenuItem) {
        let tag = sender.tag
        let info = customSpec(tag)
        guard let v = askString(title: info.title, message: info.message,
                                defaultValue: info.current),
              !v.isEmpty else { return }

        switch tag {
        case 1:  cfg.maxMemory = v
        case 2:  cfg.maxContext = v
        case 3:
            // 端口必须校验：写进去一个非法值会让服务起不来，而且 lsof 探测也会失效
            guard let n = Int(v.trimmingCharacters(in: .whitespaces)), n >= 1, n <= 65535 else {
                alert(title: "Invalid port", message: "Expected an integer between 1 and 65535, got \"\(v)\"")
                return
            }
            cfg.port = String(n)
        case 4:  cfg.maxRequestSize = v
        default: return
        }
        cfg.save()
        syncPort(cfg.port)
        askRestart("Setting updated: \(v)")
    }

    /// 各参数（tag 1…4）对应的自定义弹窗文案与当前值
    private func customSpec(_ tag: Int) -> (title: String, message: String, current: String) {
        switch tag {
        case 1:  return ("Custom max memory", "e.g. 28G / 512M", cfg.maxMemory)
        case 3:  return ("Custom port", "1-65535, e.g. 7000", cfg.port)
        case 4:  return ("Custom max request size", "e.g. 64M / 1G", cfg.maxRequestSize)
        default: return ("Custom context length", "e.g. 100K / 32768", cfg.maxContext)
        }
    }

    @objc func setAPIKey() {
        guard let v = askString(title: "API Key",
                                message: "Leave empty for no auth. When set, clients must send Authorization: Bearer <key>",
                                defaultValue: cfg.apiKey) else { return }
        cfg.apiKey = v; cfg.save(); askRestart("API key updated")
    }

    @objc func clearAPIKey() { cfg.apiKey = ""; cfg.save(); askRestart("API key cleared") }

    @objc func setHost() {
        guard let v = askString(title: "Allowed host",
                                message: "LAN IP of this Mac (e.g. 192.168.1.20) so other devices can reach it",
                                defaultValue: cfg.allowedHost) else { return }
        cfg.allowedHost = v; cfg.save(); askRestart("Allowed host set: \(v)")
    }

    @objc func clearHost() { cfg.allowedHost = ""; cfg.save(); askRestart("Reverted to localhost only") }

    @objc func setWebUIOn()  { cfg.noWebUI = false; cfg.save(); askRestart("Web UI enabled") }
    @objc func setWebUIOff() { cfg.noWebUI = true;  cfg.save(); askRestart("Web UI disabled") }

    @objc func toggleLoginItem() {
        let wanted = !cfg.loginItem
        do {
            if wanted {
                try SMAppService.mainApp.register()
                cfg.loginItem = true
                cfg.autoStartOnLaunch = true
            } else {
                try SMAppService.mainApp.unregister()
                cfg.loginItem = false
                cfg.autoStartOnLaunch = false
            }
            cfg.save()
        } catch {
            cfg.loginItem = SMAppService.mainApp.status == .enabled
            cfg.save()
            let a = NSAlert()
            a.messageText = "Could not update the login item"
            a.informativeText = """
            \(error.localizedDescription)

            You can add it manually: System Settings → General → Login Items & Extensions → Open at Login → add SplashBar.app
            """
            a.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        refresh()
    }

    @objc func openLogs() {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: logErrPath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logErrPath) {
            FileManager.default.createFile(atPath: logErrPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logErrPath))
    }

    @objc func openModelDir()  { NSWorkspace.shared.open(splashModelsDir) }
    @objc func openConfigDir() { NSWorkspace.shared.open(appSupportDir) }

    @objc func showAbout() {
        // 版本号只认 Info.plist，避免两处各写一份对不上
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "SplashBar \(appVer)"
        alert.informativeText = """
        Menu-bar controller for the local Splash inference server

        Engine: running \(Service.runningVersion() ?? "—") · installed \(Service.installedVersion() ?? "—")
        Model: \(cfg.model)
        Args: \(cfg.serveArguments.joined(separator: " "))
        Process: \(Service.recordedPID.map(String.init) ?? "none")
        Config: \(configURL.path)
        Log: \(logErrPath)
        Login item: \(SMAppService.mainApp.status == .enabled ? "registered" : "not registered")
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 菜单校验（第二道保险）

    /// 兜底：万一某处把 autoenablesItems 又开回来，AppKit 会改调这个方法来决定可用性。
    /// 判定与 rebuildMenu() 里的 isEnabled 走同一套 MenuPolicy，保证两边永不打架。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let snap = Snapshot(served: st.up, owned: Service.managed,
                            paused: Service.paused, starting: starting)
        let p = MenuPolicy(s: snap)
        let a = menuItem.action

        if a == #selector(startService)   { return p.canStart }
        if a == #selector(pauseService)   { return p.canPause }
        if a == #selector(stopService)    { return p.canStop }
        if a == #selector(restartService) { return p.canRestart }
        if a == #selector(takeOver)       { return p.canTakeOver }
        if a == #selector(openWebUI)      { return p.canOpenUI && !cfg.noWebUI }
        if a == #selector(clearAPIKey)    { return !cfg.apiKey.isEmpty }
        return true
    }

    // MARK: 辅助

    private func askRestart(_ what: String) {
        guard Service.managed || st.up else { refresh(); return }
        let alert = NSAlert()
        alert.messageText = what
        alert.informativeText = "This takes effect only after the service restarts. Restart now?"
        alert.addButton(withTitle: "Restart now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { restartService() } else { refresh() }
    }

    private func askString(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        tf.stringValue = defaultValue
        alert.accessoryView = tf
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tf
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
            ? tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    private func alert(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - CLI

private func yn(_ b: Bool) -> String { b ? "✅" : "──" }

/// 终端列宽对齐：CJK 与 emoji 按 2 列算
private func pad(_ s: String, _ width: Int) -> String {
    let w = s.unicodeScalars.reduce(0) { $0 + ($1.value >= 0x1100 ? 2 : 1) }
    return s + String(repeating: " ", count: max(0, width - w))
}

func runCLI(_ argv: [String]) -> Bool {
    guard argv.count >= 2 else { return false }
    let cmd = argv[1]
    switch cmd {
    case "--start", "--stop", "--restart", "--status", "--states", "--takeover",
         "--pause", "--resume", "--login-on", "--login-off", "--dump-menu", "--version-of":
        break
    case "--help", "-h":
        print("""
        SplashBar CLI

          SplashBar --status     Show service state and current arguments
          SplashBar --start      Start (detached session; survives quitting this app)
          SplashBar --pause      Freeze the process group with SIGSTOP (memory stays held)
          SplashBar --resume     Thaw with SIGCONT
          SplashBar --stop       Stop (kill the whole process group)
          SplashBar --restart    Restart
          SplashBar --login-on   Register as a login item (launch SplashBar and start the service at login)
          SplashBar --login-off  Unregister the login item
          SplashBar --takeover   Kill the external process holding the port and take it over
          SplashBar --states     Print the menu state-machine truth table plus the live state
          SplashBar --dump-menu  Build the real menu and recursively print item availability (post-AppKit-validation)
          SplashBar --version-of <path>  Run the version parser against an executable path (debug)
        """)
        return true
    default:
        return false
    }

    let cfg = Config.load()
    syncPort(cfg.port)              // 同上：CLI 也要先同步端口再探测
    switch cmd {
    case "--status":
        let s = Service.status()
        print("config:    \(configURL.path)")
        print("engine:    running \(Service.runningVersion() ?? "—") · installed \(Service.installedVersion() ?? "—")")
        print("model:     \(cfg.model)")
        print("args:      \(cfg.serveArguments.joined(separator: " "))")
        let state = Service.paused ? "paused"
                  : (s.up ? (Service.managed ? "running (managed)" : "running (external)") : "stopped")
        print("state:     \(state)")
        print("managed:   \(Service.managed ? "pid \(Service.recordedPID!)" : "none")")
        print("http:      \(s.up ? "ok" : "no response")")
        if s.up {
            print(String(format: "speed:     %.1f tok/s · accept %.1f%% · memory %.1f GB",
                         s.tps, s.accept * 100, s.residentGB))
        }
        print("login:     \(SMAppService.mainApp.status == .enabled ? "registered" : "not registered")")
    case "--start":
        print(Service.start(cfg: cfg))
        Thread.sleep(forTimeInterval: 3)
        print("http: \(Service.status().up ? "ok" : "no response")")
    case "--stop":
        print(Service.stop())
    case "--restart":
        print(Service.restart(cfg: cfg))
    case "--states":
        // 全量真值表：所有可达状态的菜单可用性
        let rows: [(String, Snapshot)] = [
            ("stopped", Snapshot(served: false, owned: false, paused: false, starting: false)),
            ("running (managed)", Snapshot(served: true,  owned: true,  paused: false, starting: false)),
            ("paused (managed)", Snapshot(served: false, owned: true,  paused: true,  starting: false)),
            ("starting (loading)", Snapshot(served: false, owned: true,  paused: false, starting: false)),
            ("external process", Snapshot(served: true,  owned: false, paused: false, starting: false)),
        ]
        print(pad("state", 20) + pad("start", 8) + pad("pause", 8) + pad("stop", 8) + pad("restart", 8) + pad("take", 8) + "WebUI")
        print(String(repeating: "─", count: 70))
        for (name, snap) in rows {
            let p = MenuPolicy(s: snap)
            print(pad(name, 20) + pad(yn(p.canStart), 8) + pad(yn(p.canPause), 8) + pad(yn(p.canStop), 8) + pad(yn(p.canRestart), 8) + pad(yn(p.canTakeOver), 8) + yn(p.canOpenUI))
        }
        print(String(repeating: "─", count: 70))
        let s = Service.status()
        let live = Snapshot(served: s.up, owned: Service.managed,
                            paused: Service.paused, starting: false)
        let lp = MenuPolicy(s: live)
        let label = live.paused ? "paused (managed)" : live.isLoading ? "starting (loading)"
                  : live.isExternal ? "external process" : live.served ? "running (managed)" : "stopped"
        print("live:      \(label)")
        print("           start \(yn(lp.canStart))  pause \(yn(lp.canPause))  stop \(yn(lp.canStop))  restart \(yn(lp.canRestart))  take \(yn(lp.canTakeOver))")
    case "--dump-menu":
        // 走与 App 完全相同的构建路径，再让 AppKit 跑一遍它的启用校验，
        // 打印校验之后的真实结果 —— 这是唯一能证明"置灰真的生效"的方法。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = AppDelegate()
        d.cfg = Config.load()
        d.st = Service.status()
        let menu = d.buildMenu()

        // 递归打印（子菜单也走 AppKit 的校验）；信息行单独标注，便于核对顶部布局
        func walk(_ m: NSMenu, _ indent: String, _ auto: Bool) {
            m.autoenablesItems = auto
            m.update()
            for it in m.items {
                if it.isSeparatorItem { continue }
                if it.tag == kInfoTag {
                    print("\(indent)\(pad("  info", 14))\(it.title)")
                    continue
                }
                // 只用 ✅ / ❌ 做标记：两者都是 Emoji_Presentation，列宽确定为 2。
                // 不要用 ─ 或 ·——它们属于东亚「歧义宽度」，Swift 按 2 算、终端却按 1 渲染，会错列。
                let mark = pad(it.isEnabled ? "✅ enabled" : "❌ disabled", 14)
                let arrow = it.submenu != nil ? "  ▸" : ""
                print("\(indent)\(mark)\(it.title)\(arrow)")
                if let sub = it.submenu { walk(sub, indent + "    ", auto) }
            }
        }

        func dump(_ auto: Bool, _ label: String) {
            print("")
            print("── \(label) ──")
            walk(menu, "  ", auto)
        }
        dump(false, "autoenablesItems = false (what the app runs with)")
        dump(true,  "autoenablesItems = true (AppKit overrides isEnabled)")
    case "--takeover":
        let killed = Service.pidsOnPort()
        for p in killed { kill(p, SIGTERM) }
        Thread.sleep(forTimeInterval: 1.5)
        for p in Service.pidsOnPort() { kill(p, SIGKILL) }
        try? FileManager.default.removeItem(at: pidURL)
        print("killed external process(es) [\(killed.map(String.init).joined(separator: ","))]")
        print(Service.start(cfg: cfg))
        Thread.sleep(forTimeInterval: 3)
        print("http: \(Service.status().up ? "ok" : "no response")")
    case "--pause":
        print(Service.pause())
    case "--version-of":
        // 调试验证用：把一条可执行文件路径喂给版本解析逻辑
        guard argv.count >= 3 else { print("usage: --version-of <path>"); return true }
        print(Service.versionFromPath(argv[2]) ?? "(unrecognized)")
    case "--resume":
        print(Service.resume())
    case "--login-on":
        do {
            try SMAppService.mainApp.register()
            cfg.loginItem = true; cfg.autoStartOnLaunch = true; cfg.save()
            print("login item: registered (status=\(SMAppService.mainApp.status == .enabled ? "enabled" : "notEnabled"))")
        } catch { print("register failed: \(error.localizedDescription)") }
    case "--login-off":
        do {
            try SMAppService.mainApp.unregister()
            cfg.loginItem = false; cfg.autoStartOnLaunch = false; cfg.save()
            print("login item: unregistered")
        } catch { print("unregister failed: \(error.localizedDescription)") }
    default: break
    }
    return true
}

// MARK: - main

if runCLI(CommandLine.arguments) { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
