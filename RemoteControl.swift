// Remote control: a unix-socket JSON-lines server that lets scripts and AI
// agents drive the browser the way the keyboard does — list windows and tabs,
// open pages, evaluate JavaScript, take snapshots, switch and close tabs.
//
//   socket: ~/Library/Application Support/Chromeless/control.sock  (mode 0600)
//   wire:   one JSON object per line in, one JSON object per line out
//   on:     View ▸ Remote Control (remembered), or launch with --remote
//
// A unix socket rather than a TCP port on purpose: nothing outside this
// account can connect — the file's mode is the whole permission model — and
// an ad-hoc signed build never trips the "accept incoming connections"
// prompt a TCP listener raises on every rebuild.
//
//   {"cmd": "ping"}                                → {"ok": true, ...}
//   {"cmd": "windows"}                             → windows and their tabs
//   {"cmd": "profiles"}                            → profile list + the AI's pick
//   {"cmd": "open", "url": "example.com"}          → new AI tab, background
//       add "profile": "<id or name>" to choose the profile the AI runs under
//   {"cmd": "navigate", "url": "...", "tab": 1}    → move an AI tab
//   {"cmd": "eval", "js": "document.title"}        → {"ok": true, "value": ...}
//   {"cmd": "snap", "path": "/tmp/x.png"}          or {"base64": true}
//   {"cmd": "logs", "kind": "net", "limit": 50}    → console / errors / fetch+XHR
//   {"cmd": "back"|"forward"|"reload"|"stop"|"activate"|"close", ...}
//
// "window" and "tab" are indexes into the `windows` listing; the default is
// the key window and its active tab, and every reply repeats which pair
// actually answered. Commands other than `ping`, `windows`, `profiles`, and
// `open` only work on AI tabs — tabs the socket opened, marked orange — the
// user's own tabs answer with an error instead. `eval` awaits returned
// promises, so an async expression is fine. URLs go through the same
// smartURL as ⌘L, so a bare domain or even a search phrase works.
//
// Which profile the agent runs under is the user's pick, made over the
// wire: with more than one profile the first `open` answers `needProfile`
// plus the list, the client asks its user and resends with "profile"; a
// single profile binds itself. The pick holds until the socket stops —
// agent tabs only ever join that profile's windows, and `open` orders up a
// new front-but-not-key window when none carries it.

import Cocoa
import WebKit

/// View ▸ Remote Control. Off by default — the socket lets anything running
/// as this user drive the logged-in sessions in the window, which is exactly
/// what the feature is for and exactly why it is opt-in.
enum RemoteControlPreference {
    private static let key = "ChromelessRemoteControl"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
    static func set(_ on: Bool) { UserDefaults.standard.set(on, forKey: key) }
}

let remoteControl = RemoteControlServer()

// MARK: - Agent tabs

/// Everything a remote command is allowed to touch is an "agent tab" — a tab
/// the socket itself opened, marked `isAgent` and given an orange "AI" pill
/// in the tab bar plus an orange rail at the top of the page. The user's own
/// tabs refuse commands outright, and nothing remote ever takes the user's
/// foreground: agent tabs open in the background, `activate` only switches
/// between agent tabs, and `close` never closes a window.
///
/// For debugging, agent tabs carry instrumentation the user never sees on
/// their own tabs: console messages, page errors, and fetch/XHR traffic land
/// in the tab's `agentLog`, read back with `{"cmd": "logs"}`.

/// A bounded record of one agent tab's console, errors, and network calls.
/// 400 entries FIFO — chatty pages can't grow memory without bound. Read
/// and written on the main thread only.
final class AgentLog {
    static let capacity = 400
    private(set) var entries: [[String: Any]] = []

    func add(_ entry: [String: Any]) {
        var e = entry
        e["t"] = Date().timeIntervalSince1970
        entries.append(e)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    func clear() { entries.removeAll() }
}

/// Receives the probe script's messages and files them on the tab they came
/// from, exactly the way the other routers in main.swift work — one shared
/// instance, routed by the message's own web view.
final class AgentLogRouter: NSObject, WKScriptMessageHandler {
    static let shared = AgentLogRouter()
    static let messageName = "chromelessAgentLog"

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let webView = message.webView,
              let body = message.body as? [String: Any],
              let controllers = (NSApp.delegate as? AppDelegate)?.controllers
        else { return }
        for wc in controllers {
            if let tab = wc.tabs.first(where: { $0.webView === webView }), tab.isAgent {
                tab.agentLog.add(body)
                return
            }
        }
    }
}

/// The debugging probe. It has to live in the PAGE world — `console`, `fetch`
/// and `XMLHttpRequest` in the isolated chromeless world are different
/// objects from the page's and wrapping those would see nothing. Its message
/// handler is therefore page-world too, which means a page on an agent tab
/// could post fake entries to its own agent log — accepted: the log is a
/// debugging feed for whoever drives the tab, not an audit trail.
let agentProbeScript = """
(function () {
  if (window.__chromelessAgent) return;
  window.__chromelessAgent = true;
  var post = function (m) {
    try {
      m.page = location.href;
      window.webkit.messageHandlers.chromelessAgentLog.postMessage(m);
    } catch (e) {}
  };
  var text = function (v) {
    if (v instanceof Error) return String(v.stack || v);
    try { return typeof v === "string" ? v : JSON.stringify(v); }
    catch (e) { return String(v); }
  };
  var join = function (args) {
    var out = [];
    for (var i = 0; i < args.length; i++) out.push(text(args[i]));
    return out.join(" ").slice(0, 4000);
  };
  ["log", "info", "warn", "error", "debug"].forEach(function (level) {
    var orig = console[level].bind(console);
    console[level] = function () {
      post({kind: "console", level: level, text: join(arguments)});
      return orig.apply(null, arguments);
    };
  });
  window.addEventListener("error", function (e) {
    post({kind: "error",
          text: (e.message || "error") + " @ " + (e.filename || "") + ":" + (e.lineno || 0)});
  });
  window.addEventListener("unhandledrejection", function (e) {
    post({kind: "error", text: "unhandled rejection: " + text(e.reason)});
  });
  var originalFetch = window.fetch;
  if (originalFetch) window.fetch = function (input, init) {
    var url = typeof input === "string" ? input : (input && input.url) || "";
    var method = (init && init.method) || (input && input.method) || "GET";
    var started = Date.now();
    return originalFetch.apply(this, arguments).then(function (resp) {
      post({kind: "net", method: method, url: url, status: resp.status,
            ms: Date.now() - started});
      return resp;
    }, function (err) {
      post({kind: "net", method: method, url: url, error: String(err),
            ms: Date.now() - started});
      throw err;
    });
  };
  var originalOpen = XMLHttpRequest.prototype.open;
  var originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__clAgent = {method: method, url: String(url)};
    return originalOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    var self = this, started = Date.now();
    this.addEventListener("loadend", function () {
      var meta = self.__clAgent || {method: "?", url: ""};
      post({kind: "net", method: meta.method, url: meta.url,
            status: self.status, ms: Date.now() - started});
    });
    return originalSend.apply(this, arguments);
  };
})();
"""

/// The orange rail at the top of an agent tab's page — machine-owned is
/// written on the page itself, so a glance or a screenshot can't miss it.
/// Injected main-frame only: inside iframes it would read as page chrome.
let agentRailScript = """
(function () {
  var mark = function () {
    if (document.getElementById("chromeless-agent-rail") || !document.documentElement) return;
    var el = document.createElement("div");
    el.id = "chromeless-agent-rail";
    el.setAttribute("style",
      "position:fixed;top:0;left:0;right:0;height:4px;z-index:2147483647;" +
      "background:#ff7a1a;box-shadow:0 0 0 1px rgba(0,0,0,.25);pointer-events:none;");
    document.documentElement.appendChild(el);
  };
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", mark);
  } else { mark(); }
})();
"""

/// A web configuration for agent tabs: the ordinary one plus the probe, the
/// rail, and the handler that carries log entries home.
func makeAgentConfiguration(for profile: BrowserProfile,
                            isPrivate: Bool) -> WKWebViewConfiguration {
    let conf = makeWebConfiguration(for: profile, isPrivate: isPrivate)
    conf.userContentController.add(AgentLogRouter.shared, name: AgentLogRouter.messageName)
    conf.userContentController.addUserScript(WKUserScript(
        source: agentProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    conf.userContentController.addUserScript(WKUserScript(
        source: agentRailScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    return conf
}

final class RemoteControlServer {
    static let socketPath: String = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Chromeless", isDirectory: true)
        return dir.appendingPathComponent("control.sock").path
    }()

    /// A request line longer than this is a client gone wrong, not a command.
    private let maxRequestBytes = 4 * 1024 * 1024
    private var listenFD: Int32 = -1
    private var clientFDs = Set<Int32>()
    private let fdLock = NSLock()
    private(set) var running = false
    /// The profile the user handed this agent session — set when `open`
    /// carries a valid "profile" (or binds the only one), cleared when the
    /// socket stops so the next run asks again. Main thread only, like
    /// everything it gates.
    private var agentProfileID: String?

    func startIfEnabled() {
        guard RemoteControlPreference.isOn || launchOptions.remote else { return }
        start()
    }

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    func start() {
        guard !running else { return }
        let dir = (RemoteControlServer.socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(RemoteControlServer.socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        _ = RemoteControlServer.socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: cap) { dest in
                    strncpy(dest, cstr, cap - 1)
                }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); return }
        // Same stance as ai.json and the rest of the state files: owner-only.
        chmod(RemoteControlServer.socketPath, 0o600)
        listenFD = fd
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        fdLock.lock()
        let fds = clientFDs
        clientFDs.removeAll()
        fdLock.unlock()
        for fd in fds { shutdown(fd, SHUT_RDWR); close(fd) }
        unlink(RemoteControlServer.socketPath)
        agentProfileID = nil
    }

    // MARK: Connections

    private func acceptLoop() {
        while running {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if !running || errno == EBADF || errno == EINVAL { break }
                continue
            }
            // send() would otherwise raise SIGPIPE on a half-dead client and
            // kill the whole app on a command's last byte.
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            fdLock.lock()
            clientFDs.insert(fd)
            fdLock.unlock()
            Thread.detachNewThread { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            fdLock.lock()
            clientFDs.remove(fd)
            fdLock.unlock()
            close(fd)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        readLoop: while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxRequestBytes { break }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                guard let reply = executeOnMain(line) else { break readLoop }
                var out = reply
                out.append(0x0A)
                if !sendAll(fd, out) { break readLoop }
            }
        }
    }

    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = send(fd, base.advanced(by: sent), raw.count - sent, MSG_NOSIGNAL)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Commands execute on the main thread — the only thread the window and
    /// web-view APIs are safe on — which also serialises every request the
    /// app ever sees, whatever the client does with its socket.
    private func executeOnMain(_ line: Data) -> Data? {
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            self.execute(line) { resp in
                result = try? JSONSerialization.data(withJSONObject: resp)
                done.signal()
            }
        }
        done.wait()
        return result
    }

    // MARK: Commands

    private func execute(_ data: Data, _ done: @escaping ([String: Any]) -> Void) {
        guard let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cmd = req["cmd"] as? String else {
            done(["ok": false, "error": "expected a JSON object with a \"cmd\" string"])
            return
        }
        switch cmd {
        case "ping":
            done(["ok": true, "app": "chromeless",
                  "pid": ProcessInfo.processInfo.processIdentifier,
                  "socket": RemoteControlServer.socketPath])
        case "windows":
            done(["ok": true, "windows": windowList(),
                  "agentProfile": chosenAgentProfile()?.name ?? NSNull()])
        case "profiles":
            done(["ok": true, "profiles": profileList(),
                  "agentProfile": chosenAgentProfile()?.name ?? NSNull()])
        case "open": openURL(req, done)
        case "navigate": navigate(req, done)
        case "eval": evalJS(req, done)
        case "snap": snap(req, done)
        case "logs": logs(req, done)
        case "back", "forward", "reload", "stop": navAction(cmd, req, done)
        case "activate": activate(req, done)
        case "close": closeTabOrWindow(req, done)
        default:
            done(["ok": false, "error": "unknown cmd \"\(cmd)\""])
        }
    }

    private enum Target {
        case ok(wc: BrowserWindowController, tab: Tab, wi: Int, ti: Int)
        case fail(String)
    }

    /// "window" and "tab" index into the `windows` listing; unspecified means
    /// the key window (or the first, when nothing is key) and its active tab.
    /// Resolution is agent-gated: naming one of the user's own tabs is an
    /// error, not a target.
    private func resolve(_ req: [String: Any]) -> Target {
        let controllers = (NSApp.delegate as? AppDelegate)?.controllers ?? []
        guard !controllers.isEmpty else { return .fail("no windows") }
        let wi = req["window"] as? Int
            ?? controllers.firstIndex { $0.window?.isKeyWindow == true } ?? 0
        guard controllers.indices.contains(wi) else { return .fail("no such window") }
        let wc = controllers[wi]
        let ti = req["tab"] as? Int ?? wc.activeIndex
        guard wc.tabs.indices.contains(ti) else { return .fail("no such tab") }
        let tab = wc.tabs[ti]
        guard tab.isAgent else {
            return .fail("tab \(ti) is not an AI tab — remote control only "
                + "reaches tabs it opened itself")
        }
        return .ok(wc: wc, tab: tab, wi: wi, ti: ti)
    }

    /// The stored pick — never prompts. Nil until an `open` sets it.
    private func chosenAgentProfile() -> BrowserProfile? {
        guard let id = agentProfileID else { return nil }
        return profileStore.profiles.first { $0.id == id }
    }

    private func profileList() -> [[String: Any]] {
        profileStore.profiles.map { [
            "id": $0.id,
            "name": $0.name,
            "default": $0.id == profileStore.defaultProfileID,
        ] }
    }

    /// The reply when `open` can't bind a profile itself: the client is
    /// expected to ask its user which one and resend with "profile". That
    /// question is deliberately the client's to ask — the person answering
    /// is sitting in front of the chat UI, not a Chromeless panel.
    private func needProfileReply(_ error: String) -> [String: Any] {
        ["ok": false, "error": error, "needProfile": true,
         "profiles": profileList(),
         "hint": "ask the user which profile to use, then resend with \"profile\": \"<id or name>\""]
    }

    /// The profile this `open` runs under. The choice is the user's, relayed
    /// by the client, and made once per server run: already bound, a
    /// "profile" field naming it (or none) just proceeds, while naming
    /// another is an error — the pick is not the client's to change. Not yet
    /// bound, an explicit "profile" binds it; a single profile binds itself;
    /// anything else answers `needProfile` so the user gets asked.
    private func resolveAgentProfile(_ req: [String: Any]) -> BrowserProfile? {
        let requested = (req["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let bound = chosenAgentProfile() {
            if let requested, profileStore.profile(matching: requested)?.id != bound.id {
                return nil
            }
            return bound
        }
        agentProfileID = nil
        if let requested {
            guard let picked = profileStore.profile(matching: requested) else { return nil }
            agentProfileID = picked.id
            return picked
        }
        guard profileStore.profiles.count == 1, let only = profileStore.profiles.first
        else { return nil }
        agentProfileID = only.id
        return only
    }

    /// Distinguishes "bound profile rejected the request" from "ask the
    /// user" for the `open` reply.
    private func agentProfileError(_ req: [String: Any]) -> [String: Any] {
        if let bound = chosenAgentProfile() {
            return ["ok": false, "error": "this session is bound to profile "
                + "\"\(bound.name)\" — switch remote control off and on to change it"]
        }
        if let requested = req["profile"] as? String, !requested.isEmpty {
            return needProfileReply("no profile \"\(requested)\"")
        }
        return needProfileReply("pick a profile for the AI to use")
    }

    private func windowList() -> [[String: Any]] {
        let controllers = (NSApp.delegate as? AppDelegate)?.controllers ?? []
        return controllers.enumerated().map { (i, wc) in
            [
                "index": i,
                "key": wc.window?.isKeyWindow == true,
                "title": wc.window?.title ?? "",
                "profile": wc.profileID,
                "private": wc.isPrivate,
                "tabs": wc.tabs.enumerated().map { (j, tab) in
                    [
                        "index": j,
                        "title": tab.displayTitle,
                        "url": tab.webView.url?.absoluteString ?? "",
                        "active": j == wc.activeIndex,
                        "loading": tab.webView.isLoading,
                        "startPage": tab.onStartPage,
                        "agent": tab.isAgent,
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
    }

    /// `open` is the only way a tab becomes an agent tab — it always makes a
    /// new one, always in the background, in a window carrying the profile
    /// the user picked for this agent session. It can never navigate one of
    /// the user's tabs. A `window` index pins it to that window — which must
    /// be on the agent's profile — and without one a matching window is
    /// found (the key one, then the first); when none exists a new window is
    /// ordered up for it, front but not key, so the user's focus still isn't
    /// taken. That birth is the one place remote control makes a window.
    private func openURL(_ req: [String: Any], _ done: ([String: Any]) -> Void) {
        guard let raw = req["url"] as? String, let url = smartURL(raw) else {
            done(["ok": false, "error": "open needs a \"url\" that parses"])
            return
        }
        guard let profile = resolveAgentProfile(req) else {
            done(agentProfileError(req))
            return
        }
        guard let app = NSApp.delegate as? AppDelegate else {
            done(["ok": false, "error": "no windows"])
            return
        }
        let controllers = app.controllers
        let eligible = { (wc: BrowserWindowController) in
            !wc.isPrivate && wc.profileID == profile.id
        }
        if let requested = req["window"] as? Int {
            guard controllers.indices.contains(requested) else {
                done(["ok": false, "error": "no such window"])
                return
            }
            guard eligible(controllers[requested]) else {
                done(["ok": false, "error": "window \(requested) is not on "
                    + "profile \"\(profile.name)\" — AI tabs only join the "
                    + "profile the user picked"])
                return
            }
            let tab = controllers[requested].addAgentTab(url: url)
            let ti = controllers[requested].tabs.firstIndex { $0 === tab }
                ?? controllers[requested].tabs.count - 1
            done(["ok": true, "window": requested, "tab": ti, "agent": true,
                  "foreground": false, "profile": profile.name,
                  "url": url.absoluteString])
            return
        }
        if let wi = controllers.firstIndex(where: {
                $0.window?.isKeyWindow == true && eligible($0)
            }) ?? controllers.firstIndex(where: eligible) {
            let tab = controllers[wi].addAgentTab(url: url)
            let ti = controllers[wi].tabs.firstIndex { $0 === tab }
                ?? controllers[wi].tabs.count - 1
            done(["ok": true, "window": wi, "tab": ti, "agent": true,
                  "foreground": false, "profile": profile.name,
                  "url": url.absoluteString])
            return
        }
        // Nothing on the picked profile yet: the socket opens a window for
        // it — the profile was already the user's yes — whose only tab is
        // the agent's, ordered front but never key.
        let wc = app.openWindow(profile: profile, url: url,
                                foreground: false, firstTabAgent: true)
        let wi = app.controllers.firstIndex { $0 === wc } ?? (app.controllers.count - 1)
        done(["ok": true, "window": wi, "tab": 0, "agent": true,
              "foreground": false, "profile": profile.name,
              "windowCreated": true, "url": url.absoluteString])
    }

    private func navigate(_ req: [String: Any], _ done: ([String: Any]) -> Void) {
        guard let raw = req["url"] as? String, let url = smartURL(raw) else {
            done(["ok": false, "error": "navigate needs a \"url\" that parses"])
            return
        }
        switch resolve(req) {
        case .fail(let error):
            done(["ok": false, "error": error])
        case .ok(let wc, let tab, let wi, let ti):
            wc.load(url, in: tab)
            done(["ok": true, "window": wi, "tab": ti, "url": url.absoluteString])
        }
    }

    private func evalJS(_ req: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        guard let js = req["js"] as? String else {
            done(["ok": false, "error": "eval needs a \"js\" string"])
            return
        }
        switch resolve(req) {
        case .fail(let error):
            done(["ok": false, "error": error])
        case .ok(_, let tab, let wi, let ti):
            tab.webView.evaluateJavaScript(js) { value, error in
                if let error {
                    done(["ok": false, "window": wi, "tab": ti,
                          "error": error.localizedDescription])
                    return
                }
                done(["ok": true, "window": wi, "tab": ti, "value": self.jsonSafe(value)])
            }
        }
    }

    /// evaluateJavaScript already limits itself to JSON-shaped results; what
    /// is left over — a Date, an undefined — becomes its description rather
    /// than a broken response.
    private func jsonSafe(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is NSNumber || value is String || value is NSNull { return value }
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }

    private func snap(_ req: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        switch resolve(req) {
        case .fail(let error):
            done(["ok": false, "error": error])
        case .ok(_, let tab, let wi, let ti):
            tab.webView.takeSnapshot(with: nil) { image, error in
                guard let image,
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                else {
                    done(["ok": false, "error": error?.localizedDescription ?? "snapshot failed"])
                    return
                }
                var resp: [String: Any] = ["ok": true, "window": wi, "tab": ti,
                                           "width": cg.width, "height": cg.height]
                if let path = req["path"] as? String {
                    do {
                        try png.write(to: URL(fileURLWithPath: path))
                        resp["path"] = path
                    } catch {
                        resp = ["ok": false, "error": error.localizedDescription]
                    }
                } else {
                    resp["png"] = png.base64EncodedString()
                }
                done(resp)
            }
        }
    }

    /// The agent's own debugging feed: console lines, page errors, and
    /// fetch/XHR calls the probe captured in this tab. `kind` narrows it
    /// ("console", "error", "net"), `limit` tails the last N (default 100,
    /// capped at the buffer's 400), and `clear` drains it after reading.
    private func logs(_ req: [String: Any], _ done: ([String: Any]) -> Void) {
        switch resolve(req) {
        case .fail(let error):
            done(["ok": false, "error": error])
        case .ok(_, let tab, let wi, let ti):
            var entries = tab.agentLog.entries
            if let kind = req["kind"] as? String {
                entries = entries.filter { ($0["kind"] as? String) == kind }
            }
            let limit = min(max(req["limit"] as? Int ?? 100, 1), AgentLog.capacity)
            let tail = Array(entries.suffix(limit))
            if req["clear"] as? Bool == true { tab.agentLog.clear() }
            done(["ok": true, "window": wi, "tab": ti, "entries": tail])
        }
    }

    private func navAction(_ cmd: String, _ req: [String: Any],
                           _ done: ([String: Any]) -> Void) {
        switch resolve(req) {
        case .fail(let error):
            done(["ok": false, "error": error])
        case .ok(_, let tab, let wi, let ti):
            let wv = tab.webView
            switch cmd {
            case "back": wv.goBack()
            case "forward": wv.goForward()
            case "reload": wv.reload()
            default: wv.stopLoading()
            }
            done(["ok": true, "window": wi, "tab": ti])
        }
    }

    /// Selecting an agent tab is only allowed while the user is already on an
    /// agent tab — switching between two AI tabs touches nothing the user was
    /// looking at, while switching away from a user's tab would steal the
    /// foreground the rules promise to leave alone. It also never raises the
    /// window or the app; the user's focus is theirs.
    private func activate(_ req: [String: Any], _ done: ([String: Any]) -> Void) {
        switch resolve(req) {
        case .fail(let error):
            done(["ok": false, "error": error])
        case .ok(let wc, _, let wi, let ti):
            guard wc.activeTab.isAgent else {
                done(["ok": false, "error": "the front tab is the user's — "
                    + "switching away from it would take the foreground"])
                return
            }
            wc.selectTab(at: ti)
            done(["ok": true, "window": wi, "tab": ti])
        }
    }

    /// Close is tab-only: remote control never closes a window, because a
    /// window can hold the user's tabs too. With no "tab" it means the active
    /// tab — which still has to be an agent tab to close.
    private func closeTabOrWindow(_ req: [String: Any], _ done: ([String: Any]) -> Void) {
        if req["window"] != nil && req["tab"] == nil {
            done(["ok": false, "error": "remote control closes tabs, not windows "
                + "— name a \"tab\""])
            return
        }
        switch resolve(req) {
        case .fail(let error):
            done(["ok": false, "error": error])
        case .ok(let wc, _, let wi, let ti):
            wc.closeTab(at: ti)
            done(["ok": true, "window": wi, "tab": ti])
        }
    }
}
