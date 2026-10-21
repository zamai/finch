import Cocoa

private let kInternetEventClass = AEEventClass(0x4755524C)  // 'GURL'
private let kAEGetURL           = AEEventID(0x4755524C)     // 'GURL'
private let keyDirectObject     = AEKeyword(0x2D2D2D2D)     // '----'
private let keySenderPID        = AEKeyword(0x73706964)     // 'spid'

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var engine: Engine?
    private var statusItem: NSStatusItem?
    /// bundle id -> human name, so building the menu does not hit LaunchServices
    /// once per item every time it opens.
    private var browserNames: [String: String] = [:]
    /// `.app` -> its Mach-O, so the relay path does not re-read Info.plist.
    private var executables: [URL: URL?] = [:]
    /// bundle id -> `.app`, so the hot path does not ask LaunchServices twice
    /// for the same answer.
    private var appURLs: [String: URL?] = [:]
    /// fork/exec is cheap but not free, and nothing waits on the result.
    private let spawnQueue = DispatchQueue(label: "com.finch.browser.spawn", qos: .userInitiated)

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:reply:)),
            forEventClass: kInternetEventClass,
            andEventID: kAEGetURL
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        reloadEngine()
        setupMenuBar()
        signal(SIGHUP) { _ in
            DispatchQueue.main.async { (NSApp.delegate as? AppDelegate)?.reloadEngine() }
        }

        let args = CommandLine.arguments.dropFirst()
        if let ti = args.firstIndex(of: "--test"), args.indices.contains(ti + 1) {
            testURL(String(args[ti + 1]))
            NSApp.terminate(nil)
        }
        if let bi = args.firstIndex(of: "--bench"),
           args.indices.contains(bi + 1), args.indices.contains(bi + 2) {
            bench(n: Int(args[bi + 1]) ?? 10_000, url: String(args[bi + 2]))
            NSApp.terminate(nil)
        }
    }

    // MARK: - Hot path

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        let trace = RouteTrace()
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let engine else { return }

        let opener    = openerBundleId(from: event)
        trace.mark("opener")
        let modifiers = NSEvent.modifierFlags
        trace.mark("mods")

        let result = engine.resolve(urlString: raw, opener: opener, modifiers: modifiers)
        trace.mark("resolve")
        // Rules match on bundle id; the menu prefers it too, but falls back to
        // the sender's executable name so a non-app sender reads as "osascript"
        // rather than an unexplained blank.
        let from = opener.isEmpty ? senderExecutableName(from: event) : opener
        let id = RouteHistory.shared.record(opener: from,
                               original: raw,
                               final: result.url.absoluteString,
                               bundleId: result.browser.bundleId)
        trace.mark("record")
        trace.from = from
        if result.browser.bundleId.isEmpty {            // suppressed (open: null)
            trace.emit("suppressed")
            return
        }
        open(url: result.url, spec: result.browser, trace: trace, entry: id)
    }

    /// Bundle id of the sending app, for `from()` rules and the menu.
    /// Must come from the event's sender pid, not `frontmostApplication`:
    /// handling a GURL event makes Finch frontmost, so that answers
    /// "com.finch.browser" for every link and no `from()` rule can match.
    private func openerBundleId(from event: NSAppleEventDescriptor) -> String {
        let mine = Bundle.main.bundleIdentifier
        if let pid = event.attributeDescriptor(forKeyword: keySenderPID)?.int32Value, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid),
           let bundleId = app.bundleIdentifier, bundleId != mine {
            return bundleId
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return front == mine ? "" : front
    }

    /// Executable name for senders that are not apps and have no bundle id.
    /// Display-only — `from()` matches bundle ids, never this.
    private func senderExecutableName(from event: NSAppleEventDescriptor) -> String {
        guard let pid = event.attributeDescriptor(forKeyword: keySenderPID)?.int32Value, pid > 0
        else { return "" }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    private func open(url: URL, spec: BrowserSpec, trace: RouteTrace, entry: Int) {
        guard let appURL = appURL(for: spec.bundleId) else {
            fputs("finch: browser not found: \(spec.bundleId)\n", stderr)
            // Deliberately not NSWorkspace.open(url): Finch is the default
            // handler, so that would hand the URL straight back to Finch.
            trace.emit("notfound=\(spec.bundleId)")
            return
        }
        trace.mark("lookup")
        // The completion handler is where the real answer is: everything above
        // it is bookkeeping, and the open only returns once LaunchServices has
        // handed the URL to the browser process.
        func done(_ via: String) -> (NSRunningApplication?, Error?) -> Void {
            return { _, err in
                trace.mark("handoff")
                self.settle(entry, trace, "-> \(spec.bundleId) via=\(via)" + (err == nil ? "" : " err=\(err!)"))
            }
        }

        let cfg = NSWorkspace.OpenConfiguration()
        if spec.args.isEmpty {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg,
                                    completionHandler: done("open"))
            trace.mark("issue")
            return
        }

        // macOS drops launch arguments when the app is already running, so a
        // profile flag would be ignored. A browser that is not running yet has
        // no such problem: launch it normally and the arguments are honoured.
        let live = NSRunningApplication.runningApplications(withBundleIdentifier: spec.bundleId).first
        trace.mark("running")
        if live == nil {
            cfg.arguments = spec.args + [url.absoluteString]
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg,
                                               completionHandler: done("launch"))
            trace.mark("issue")
            return
        }

        // Already running, so the arguments have to reach it on a fresh command
        // line — or, for a Chromium browser, straight down the socket a relay
        // process would have used. That is the whole latency of a
        // profile-routed link, so it is worth the one unsupported dependency;
        // Singleton falls back here on anything it does not understand.
        guard let exe = executable(of: appURL) else {
            cfg.arguments = spec.args + [url.absoluteString]
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg,
                                               completionHandler: done("newinstance"))
            trace.mark("issue")
            return
        }
        trace.mark("exe")
        let argv = [exe.path] + spec.args + [url.absoluteString]
        let socket = Singleton.socketPath(bundleId: spec.bundleId, dataDir: spec.dataDir)
        spawnQueue.async {
            if let socket {
                switch Singleton.send(argv: argv, to: socket) {
                case .ack:
                    trace.mark("socket")
                    // Nothing has raised the browser: unlike a LaunchServices
                    // launch, neither the socket nor a bare fork/exec activates
                    // it, and a link that opens a tab you cannot see has not
                    // really opened.
                    live?.activate(options: [])
                    trace.mark("activate")
                    self.settle(entry, trace, "-> \(spec.bundleId) via=socket")
                    return
                case .declined(let why):
                    trace.mark("socketdeclined")
                    trace.note = "socket declined: \(why)"
                case .unreachable(let why):
                    trace.mark("socketmiss")
                    trace.note = "socket unreachable: \(why)"
                }
            }
            // Spawning the bundle's executable is the same thing
            // `open -n -a <app> --args …` does — single-instance browsers hand
            // the URL to the running process and exit — minus LaunchServices'
            // launch machinery, which measured ~70ms slower and spiked past
            // 250ms under load.
            let p = Process()
            p.executableURL = exe
            p.arguments = argv
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            // The relay process exits once the running browser has the URL,
            // which is the moment the user is waiting for. Nothing blocks on
            // it; the handler only exists so the log says how long it took.
            p.terminationHandler = { _ in
                trace.mark("relay")
                live?.activate(options: [])
                self.settle(entry, trace, "-> \(spec.bundleId) via=relay")
            }
            do { try p.run() } catch {
                self.settle(entry, trace, "-> \(spec.bundleId) via=relay spawnerr=\(error)")
                return
            }
            trace.mark("spawn")
        }
        trace.mark("issue")
    }

    /// Close out a route: write the trace line, and put the figure in the menu
    /// so "that one felt slow" can be checked without opening a log file.
    private func settle(_ entry: Int, _ trace: RouteTrace, _ summary: String) {
        let ms = trace.elapsedMs
        trace.emit(summary)
        DispatchQueue.main.async { RouteHistory.shared.finish(entry, ms: ms) }
    }

    /// `Finch.app/Contents/MacOS/Finch` for a given `.app`. Cached: it means
    /// reading the bundle's Info.plist, which is not free and never changes.
    private func executable(of appURL: URL) -> URL? {
        if let cached = executables[appURL] { return cached }
        let exe = Bundle(url: appURL)?.executableURL
        executables[appURL] = exe
        return exe
    }

    /// Cached LaunchServices lookup — ~1ms per route otherwise, for an answer
    /// that only changes when a browser is installed or moved. Reloading the
    /// config clears it, which is the one moment the user is thinking about
    /// which browsers exist.
    private func appURL(for bundleId: String) -> URL? {
        if let cached = appURLs[bundleId] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        appURLs[bundleId] = url
        return url
    }

    // MARK: - Helpers

    private func reloadEngine() {
        appURLs.removeAll(); executables.removeAll(); browserNames.removeAll()
        guard let loaded = loadConfig() else { return }
        do { engine = try Engine(loaded: loaded) }
        catch { fputs("finch: engine init failed: \(error)\n", stderr) }
    }

    private func testURL(_ raw: String) {
        guard let engine else { print("finch: no config loaded"); return }
        let result = engine.resolve(urlString: raw, opener: "test.app", modifiers: [])
        print("URL:     \(raw)")
        print("Final:   \(result.url)")
        print("Browser: \(result.browser.bundleId)")
        if !result.browser.args.isEmpty { print("Args:    \(result.browser.args.joined(separator: " "))") }
    }

    private func bench(n: Int, url: String) {
        guard let engine else { print("finch: no config loaded"); return }
        for _ in 0 ..< min(n / 10, 1_000) {
            _ = engine.resolve(urlString: url, opener: "com.tinyspeck.slackmacgap", modifiers: [])
        }
        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        for _ in 0 ..< n {
            _ = engine.resolve(urlString: url, opener: "com.tinyspeck.slackmacgap", modifiers: [])
        }
        let elapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start
        let nsPerOp = elapsed / UInt64(n)
        let usPerOp = Double(elapsed) / Double(n) / 1_000
        print("Benchmark: \(n) iterations")
        print("Total:     \(elapsed / 1_000_000)ms")
        print("Per-op:    \(nsPerOp)ns  (\(String(format: "%.2f", usPerOp))µs)")
        let r = engine.resolve(urlString: url, opener: "com.tinyspeck.slackmacgap", modifiers: [])
        print("URL:       \(url)")
        print("Browser:   \(r.browser.bundleId)")
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = "🐦"
        let menu = NSMenu()
        menu.delegate = self          // items built lazily in menuNeedsUpdate
        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Recent Links", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let recent = RouteHistory.shared.recent
        if recent.isEmpty {
            let empty = NSMenuItem(title: "  None yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in recent { menu.addItem(recentItem(for: entry)) }
        }

        menu.addItem(.separator())
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Finch", action: #selector(NSApp.terminate), keyEquivalent: "q")
    }

    /// One recent route: "  github.com/foo/bar \u{2192} Chrome". Click copies the URL.
    private func recentItem(for entry: RouteEntry) -> NSMenuItem {
        let target = entry.suppressed ? "blocked" : browserName(entry.bundleId)
        let took = entry.ms.map { String(format: "  %.0fms", $0) } ?? ""
        let item = NSMenuItem(title: "  \(shorten(entry.final)) \u{2192} \(target)\(took)",
                              action: #selector(copyRecentURL(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.final
        var tip = entry.final + "\n\u{2192} " + (entry.suppressed ? "suppressed (open: null)" : entry.bundleId)
        if !entry.opener.isEmpty { tip += "\nfrom \(entry.opener)" }
        if entry.rewritten { tip += "\nrewritten from \(entry.original)" }
        tip += "\n\nClick to copy URL"
        item.toolTip = tip
        return item
    }

    /// Drop the scheme and elide the middle — menu items are read at a glance.
    private func shorten(_ url: String, max: Int = 52) -> String {
        var s = url
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        guard s.count > max else { return s }
        return "\(s.prefix(max - 18))\u{2026}\(s.suffix(15))"
    }

    private func browserName(_ bundleId: String) -> String {
        if let cached = browserNames[bundleId] { return cached }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        } else {
            name = bundleId   // not installed — the raw id is the useful bit here
        }
        browserNames[bundleId] = name
        return name
    }

    @objc private func reloadConfig() { reloadEngine() }

    @objc private func copyRecentURL(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

}
