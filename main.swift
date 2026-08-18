// chromeless — the browser that isn't there.
//
// A single-file macOS browser with almost no chrome: no toolbar, no address
// bar, and no tab bar until you open a second tab — just the page, in a bare
// rounded window. Built on WKWebView (the Safari engine). Made for clean
// screenshots and fullscreen video.
//
//   ⌘L  search / open url        ⇧⌘S  snapshot page → Desktop
//   ⌘R  reload                   ⌘P   pin window on top
//   ⌘[ ⌘]  back / forward        ⌃⌘F  fullscreen
//   ⌘= ⌘- ⌘0  zoom               ⌘drag  move the window
//   ⌘T  new tab                  ⌃Tab  next tab
//   ⇧⌘B  allow ads here          ⌃⇧⌘E  pick an element to hide
//   ⌘click  link → background tab   ⇧⌘click  → foreground tab
//
// CLI screenshot mode:
//   chromeless https://example.com --snap out.png --size 1440x900 --wait 2

import Cocoa
import Security
import WebKit

// MARK: - Passkey capability

// WKWebView performs WebAuthn (passkeys via iCloud Keychain / Touch ID) only for
// apps signed with Apple's restricted web-browser.public-key-credential
// entitlement, which needs an Apple-issued provisioning profile — macOS kills
// ad-hoc builds that claim it. So: if this build carries the entitlement,
// passkeys just work; if not, hide the WebAuthn API so sites feature-detect the
// absence and offer their fallback sign-in (password, phone prompt) instead of
// a passkey ceremony that is guaranteed to fail. See README for enabling it.
let hasPasskeyEntitlement: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
    return (value as? Bool) == true
}()

// MARK: - URL smarts

func smartURL(_ input: String) -> URL? {
    let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    if t.hasPrefix("/") || t.hasPrefix("~") {
        let path = (t as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
    }
    if t.contains("://") { return URL(string: t) }
    let lower = t.lowercased()
    for host in ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"] where lower.hasPrefix(host) {
        return URL(string: "http://" + t)
    }
    if !t.contains(" "), t.contains(".") { return URL(string: "https://" + t) }
    let q = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t
    return URL(string: "https://www.google.com/search?q=" + q)
}

// MARK: - Launch options

struct SnapJob { let path: String; let wait: TimeInterval }

struct LaunchOptions {
    var url: URL? = nil
    var snap: SnapJob? = nil
    var size: NSSize? = nil
    var restoreLastPage = false
    var profile: String? = nil
    var listProfiles = false
}

func parseLaunchOptions() -> LaunchOptions {
    var opts = LaunchOptions()
    var snapPath: String? = nil
    var wait: TimeInterval = 1.0
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--help", "-h":
            print("""
            chromeless — the browser that isn't there

            usage: chromeless [url] [options]
              --snap <path>     load the page, save a PNG of it, and quit
              --size <WxH>      window size in points (e.g. 1440x900)
              --wait <seconds>  extra settle time before --snap (default 1.0)
              --restore         reopen the last saved page instead of the start page
              --profile <name>  use a specific profile
              --profiles        list profiles and exit
              --adblock-selftest  check the filter converter and exit

            examples:
              chromeless youtube.com
              chromeless localhost:3000 --snap shot.png --size 1280x800
              chromeless --profile work onedrive.live.com
            """)
            exit(0)
        case "--snap":
            i += 1
            if i < args.count { snapPath = args[i] }
        case "--size":
            i += 1
            if i < args.count {
                let parts = args[i].lowercased().split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { opts.size = NSSize(width: parts[0], height: parts[1]) }
            }
        case "--wait":
            i += 1
            if i < args.count { wait = Double(args[i]) ?? 1.0 }
        case "--restore":
            opts.restoreLastPage = true
        case "--profile":
            i += 1
            if i < args.count { opts.profile = args[i] }
        case "--profiles":
            opts.listProfiles = true
        case "--adblock-selftest":
            runAdBlockSelfTest()
        case "--adblock-compiletest":
            runAdBlockCompileTest()
        default:
            if a.hasPrefix("-") {
                fputs("chromeless: ignoring unknown option \(a)\n", stderr)
            } else if let u = smartURL(a) {
                opts.url = u
            }
        }
        i += 1
    }
    if let p = snapPath {
        let abs = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
        opts.snap = SnapJob(path: abs, wait: wait)
    }
    return opts
}

let launchOptions = parseLaunchOptions()

// MARK: - Profiles

struct BrowserProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var dataStoreID: String
    var lastURL: String?
    var history: [String]
    var createdAt: Date
    var updatedAt: Date

    var dataStoreUUID: UUID {
        UUID(uuidString: dataStoreID) ?? UUID(uuidString: "F4D7F032-4548-4E72-98A3-3F6F9946E6E3")!
    }
}

struct ProfileArchive: Codable {
    var defaultProfileID: String?
    var profiles: [BrowserProfile]
}

final class ProfileStore {
    private static let defaultDataStoreID = "F4D7F032-4548-4E72-98A3-3F6F9946E6E3"
    private(set) var defaultProfileID = "default"
    private(set) var profiles: [BrowserProfile] = []
    private let directoryURL: URL
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directoryURL = appSupport.appendingPathComponent("Chromeless/Profiles", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("profiles.json")
        load()
    }

    var defaultProfile: BrowserProfile {
        profiles.first { $0.id == defaultProfileID }
            ?? profiles.first { $0.id == "default" }
            ?? profiles[0]
    }

    var usesPersistentProfileStores: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    func profile(matching value: String?) -> BrowserProfile? {
        guard let value, !value.isEmpty else { return defaultProfile }
        let needle = value.lowercased()
        return profiles.first {
            $0.id.lowercased() == needle || $0.name.lowercased() == needle
        }
    }

    func websiteDataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: profile.dataStoreUUID)
        }
        return .nonPersistent()
    }

    func createProfile(named rawName: String) throws -> BrowserProfile {
        let cleanName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleanName.isEmpty ? "New Profile" : cleanName
        let id = uniqueID(from: name)
        let now = Date()
        let profile = BrowserProfile(
            id: id,
            name: name,
            dataStoreID: UUID().uuidString,
            lastURL: nil,
            history: [],
            createdAt: now,
            updatedAt: now)
        profiles.append(profile)
        try ensureDirectory(for: profile)
        save()
        return profile
    }

    func setDefaultProfile(_ profile: BrowserProfile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        defaultProfileID = profile.id
        save()
    }

    func deleteProfile(_ profile: BrowserProfile, completion: @escaping (Error?) -> Void) {
        guard profiles.count > 1 else {
            completion(NSError(
                domain: "ChromelessProfiles", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Chromeless needs at least one profile."]))
            return
        }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            completion(NSError(
                domain: "ChromelessProfiles", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Profile not found."]))
            return
        }

        let removed = profiles.remove(at: index)
        if defaultProfileID == removed.id {
            defaultProfileID = profiles.first { $0.id == "default" }?.id ?? profiles[0].id
        }
        save()

        do {
            let folder = directoryURL.appendingPathComponent(removed.id, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            completion(error)
            return
        }

        if #available(macOS 14.0, *) {
            WKWebsiteDataStore.remove(forIdentifier: removed.dataStoreUUID) { error in
                completion(error)
            }
        } else {
            completion(nil)
        }
    }

    func recordVisit(_ url: URL, for profile: BrowserProfile) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let value = url.absoluteString
        profiles[index].lastURL = value
        profiles[index].history.removeAll { $0 == value }
        profiles[index].history.append(value)
        if profiles[index].history.count > 200 {
            profiles[index].history.removeFirst(profiles[index].history.count - 200)
        }
        profiles[index].updatedAt = Date()
        save()
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let archive = try JSONDecoder().decode(ProfileArchive.self, from: data)
                profiles = archive.profiles
                defaultProfileID = archive.defaultProfileID ?? "default"
            }
            if profiles.isEmpty {
                let now = Date()
                profiles = [BrowserProfile(
                    id: "default",
                    name: "Default",
                    dataStoreID: Self.defaultDataStoreID,
                    lastURL: UserDefaults.standard.string(forKey: "LastURL"),
                    history: [],
                    createdAt: now,
                    updatedAt: now)]
            }
            normalizeProfiles()
            normalizeDefaultProfile()
            for profile in profiles { try ensureDirectory(for: profile) }
            save()
        } catch {
            fputs("chromeless: could not load profiles: \(error.localizedDescription)\n", stderr)
            let now = Date()
            profiles = [BrowserProfile(
                id: "default",
                name: "Default",
                dataStoreID: Self.defaultDataStoreID,
                lastURL: nil,
                history: [],
                createdAt: now,
                updatedAt: now)]
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(ProfileArchive(
                defaultProfileID: defaultProfile.id,
                profiles: profiles))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            fputs("chromeless: could not save profiles: \(error.localizedDescription)\n", stderr)
        }
    }

    private func normalizeProfiles() {
        for index in profiles.indices {
            if UUID(uuidString: profiles[index].dataStoreID) == nil ||
                profiles[index].dataStoreID == "00000000-0000-0000-0000-000000000001" {
                profiles[index].dataStoreID = profiles[index].id == "default"
                    ? Self.defaultDataStoreID
                    : UUID().uuidString
                profiles[index].updatedAt = Date()
            }
        }
    }

    private func normalizeDefaultProfile() {
        if !profiles.contains(where: { $0.id == defaultProfileID }) {
            defaultProfileID = profiles.first { $0.id == "default" }?.id ?? profiles[0].id
        }
    }

    private func ensureDirectory(for profile: BrowserProfile) throws {
        try FileManager.default.createDirectory(
            at: directoryURL.appendingPathComponent(profile.id, isDirectory: true),
            withIntermediateDirectories: true)
    }

    private func uniqueID(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let base = folded.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var id = String(base).split(separator: "-").joined(separator: "-")
        if id.isEmpty { id = "profile" }
        var candidate = id
        var suffix = 2
        while profiles.contains(where: { $0.id == candidate }) {
            candidate = "\(id)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

let profileStore = ProfileStore()
if launchOptions.listProfiles {
    for profile in profileStore.profiles {
        let marker = profile.id == profileStore.defaultProfile.id ? "*" : " "
        print("\(marker) \(profile.id)\t\(profile.name)")
    }
    exit(0)
}

// MARK: - Start page

// The page is handed to WebKit as a bare string with no base URL, so it cannot
// pull in a stylesheet, a script, or an image file — everything it needs is
// inline, and the quick-access icons ride along as base64 data URIs.
private let startPageTemplate = #"""
<!doctype html>
<html><head><meta charset="utf-8"><title>chromeless</title>
<style>
  html, body { height: 100%; margin: 0; }
  body { background: #0a0a0e; color: #e8e8ee; font: 15px/1.6 -apple-system, system-ui;
         display: flex; justify-content: center; overflow-y: auto;
         -webkit-user-select: none; cursor: default; }
  /* `margin: auto` centres the same way `align-items: center` does, minus its
     one flaw: when the list is taller than the window, that property overflows
     equally in both directions and the top scrolls out of reach. */
  main { text-align: center; max-width: 680px; padding: 48px; margin: auto;
         animation: in .6s ease-out; }
  @keyframes in { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; } }
  h1 { font-size: 46px; font-weight: 650; letter-spacing: -.02em; margin: 0 0 6px; color: #fff; }
  p.tag { color: #85858f; margin: 0 0 46px; font-size: 16px; }
  .keys { display: grid; grid-template-columns: auto auto; gap: 11px 22px;
          justify-content: center; text-align: left; font-size: 13.5px; color: #b9b9c4; }
  .k { text-align: right; }
  kbd { font: 600 12px ui-monospace, "SF Mono", monospace; background: #1b1b22;
        border: 1px solid #2c2c36; border-bottom-width: 2px; border-radius: 6px;
        padding: 2.5px 8px; color: #e8e8ee; white-space: nowrap; }
  footer { margin-top: 44px; color: #55555e; font-size: 12px; line-height: 2; }
  footer b { color: #8a8a97; font-weight: 600; }

  /* Quick access — a footnote under the keys, not a headline above them. */
  .qa { margin: 36px 0 0; }
  .qa-head { display: inline-flex; align-items: center; gap: 7px; padding: 3px 9px;
             border: 0; border-radius: 7px; background: none; cursor: pointer;
             font: 11.5px -apple-system, system-ui; letter-spacing: .04em; color: #55555e; }
  .qa-head:hover { background: #14141a; color: #8a8a97; }
  .chev { font-size: 9px; transform: rotate(90deg); transition: transform .15s; }
  .qa[data-collapsed] .chev { transform: rotate(0deg); }
  .qa[data-collapsed] .grid { display: none; }
  .count { color: #3b3b45; }
  .grid { display: grid; grid-template-columns: repeat(5, 76px); gap: 10px;
          justify-content: center; margin: 13px 0 0; }
  .slot { position: relative; height: 66px; border-radius: 11px; display: flex;
          flex-direction: column; align-items: center; justify-content: center; gap: 6px;
          background: #121218; border: 1px solid #1f1f28; cursor: pointer;
          transition: background .12s, border-color .12s, transform .12s; }
  .slot:hover { background: #181820; border-color: #31313c; transform: translateY(-1px); }
  .slot img, .mono { width: 24px; height: 24px; border-radius: 6px; }
  .mono { display: grid; place-items: center; background: #24242f; color: #cfcfdb;
          font: 600 12px -apple-system, system-ui; text-transform: uppercase; }
  .name { max-width: 62px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
          font-size: 10.5px; color: #9a9aa6; }
  .empty { background: none; border: 1px dashed #21212a; color: #313139; font-size: 16px;
           font-weight: 300; }
  .empty:hover { background: none; border-color: #3a3a47; color: #6c6c80; }
  .pen { position: absolute; top: 3px; right: 3px; width: 17px; height: 17px; border-radius: 6px;
         display: grid; place-items: center; font-size: 9px; color: #8a8a97; background: #24242e;
         opacity: 0; transition: opacity .12s; }
  .slot:hover .pen { opacity: 1; }
  .pen:hover { background: #353542; color: #fff; }

  /* Add / edit sheet */
  .sheet { position: fixed; inset: 0; background: #05050880; backdrop-filter: blur(6px);
           display: none; place-items: center; z-index: 10; }
  .sheet[data-open] { display: grid; }
  .card { width: 340px; text-align: left; background: #16161d; border: 1px solid #2c2c36;
          border-radius: 16px; padding: 22px; box-shadow: 0 24px 60px #00000080; }
  .card h2 { margin: 0 0 16px; font-size: 16px; font-weight: 600; color: #fff; }
  .card label { display: block; font-size: 11.5px; color: #7c7c88; margin: 0 0 4px;
                text-transform: uppercase; letter-spacing: .05em; }
  .card input { width: 100%; box-sizing: border-box; margin: 0 0 14px; padding: 9px 11px;
                background: #0e0e13; border: 1px solid #2c2c36; border-radius: 9px;
                color: #e8e8ee; font: 13.5px -apple-system, system-ui; outline: none;
                -webkit-user-select: text; cursor: text; }
  .card input:focus { border-color: #4a4a5c; }
  .err { min-height: 16px; margin: -8px 0 10px; font-size: 12px; color: #e2686f; }
  .row { display: flex; align-items: center; gap: 8px; }
  .row .spacer { flex: 1; }
  .card button { padding: 7px 14px; border-radius: 9px; border: 1px solid #2c2c36;
                 background: #1e1e26; color: #d8d8e2; font: 13px -apple-system, system-ui;
                 cursor: pointer; }
  .card button:hover { background: #26262f; }
  .card button.save { background: #3a6df0; border-color: #3a6df0; color: #fff; }
  .card button.save:hover { background: #4a7bf5; }
  .card button.drop { border-color: transparent; background: none; color: #98545a; }
  .card button.drop:hover { background: #2a1a1d; color: #e2686f; }
</style></head>
<body><main>
  <h1>chromeless</h1>
  <p class="tag">the browser that isn&rsquo;t there</p>
  <div class="keys">
    <div class="k"><kbd>&#8984; L</kbd></div>       <div>search or enter a url</div>
    <div class="k"><kbd>&#8984; T</kbd></div>       <div>new tab &mdash; the tab bar shows up from the second one</div>
    <div class="k"><kbd>&#8963;&#8677;</kbd></div>  <div>next tab &mdash; <kbd>&#8984;1</kbd>&hellip;<kbd>&#8984;9</kbd> jump straight there</div>
    <div class="k"><kbd>&#8984; drag</kbd></div>    <div>move the window</div>
    <div class="k"><kbd>&#8984; click</kbd></div>   <div>open a link in a background tab &mdash; middle-click too, <kbd>&#8679;&#8984;</kbd> to jump there</div>
    <div class="k"><kbd>&#8963;&#8984; F</kbd></div><div>fullscreen</div>
    <div class="k"><kbd>&#8679;&#8984; S</kbd></div><div>snapshot the page &rarr; desktop</div>
    <div class="k"><kbd>&#8984; P</kbd></div>       <div>pin on top of every window</div>
    <div class="k"><kbd>&#8984; [</kbd> <kbd>&#8984; ]</kbd></div><div>back / forward</div>
    <div class="k"><kbd>&#8679;&#8984; H</kbd></div><div>home &mdash; back to this page</div>
    <div class="k"><kbd>&#8984; =</kbd> <kbd>&#8984; &minus;</kbd> <kbd>&#8984; 0</kbd></div><div>zoom</div>
    <div class="k"><kbd>&#8679;&#8984; C</kbd></div><div>copy current url</div>
    <div class="k"><kbd>&#8679;&#8984; B</kbd></div><div>ads are blocked everywhere &mdash; this lets them through on one site</div>
    <div class="k"><kbd>&#8963;&#8679;&#8984; E</kbd></div><div>point at anything on the page and hide it for good</div>
  </div>
  <section class="qa" id="qa">
    <button type="button" class="qa-head" id="qa-head" aria-expanded="true">
      <span class="chev">&#9656;</span> quick access <span class="count" id="qa-count"></span>
    </button>
    <div class="grid" id="qa-grid"></div>
  </section>
  <footer>&#8984;N profile window &nbsp;&middot;&nbsp; &#8679;&#8984;J downloads &nbsp;&middot;&nbsp; &#8984;R reload &nbsp;&middot;&nbsp; &#8984;W close tab &nbsp;&middot;&nbsp; &#8679;&#8984;W close window
  <br>quick access: click a tile to go, &#8984;-click for a background tab, &#9998; to edit &mdash; icons fetch themselves
  <br>filter lists, your own rules, and the sites you allowed live in <b>View &rsaquo; Ad Blocking</b></footer>
</main>

<div class="sheet" id="sheet">
  <form class="card" id="form">
    <h2 id="heading">Add a shortcut</h2>
    <label for="url">Address</label>
    <input id="url" placeholder="example.com" spellcheck="false" autocapitalize="off">
    <label for="title">Name</label>
    <input id="title" maxlength="60" placeholder="Taken from the site if left blank">
    <p class="err" id="err"></p>
    <div class="row">
      <button type="button" class="drop" id="drop" hidden>Remove</button>
      <span class="spacer"></span>
      <button type="button" id="cancel">Cancel</button>
      <button type="submit" class="save">Save</button>
    </div>
  </form>
</div>
<script>
(function () {
  var state = __QUICK_ACCESS__;
  var section = document.getElementById("qa");
  var head = document.getElementById("qa-head");
  var count = document.getElementById("qa-count");
  var grid = document.getElementById("qa-grid");
  var sheet = document.getElementById("sheet");
  var form = document.getElementById("form");
  var heading = document.getElementById("heading");
  var urlField = document.getElementById("url");
  var titleField = document.getElementById("title");
  var errLine = document.getElementById("err");
  var dropButton = document.getElementById("drop");
  var editingID = null;

  function post(message) {
    try { window.webkit.messageHandlers.chromelessQuickAccess.postMessage(message); } catch (e) {}
  }

  function initial(link) {
    var source = (link.title || link.url.replace(/^[a-z]+:\/\/(www\.)?/i, "")).trim();
    return source ? source.charAt(0) : "?";
  }

  // Built node by node rather than with innerHTML: a page title is arbitrary
  // text off the internet, and textContent is the one place it cannot bite.
  function tile(link) {
    var slot = document.createElement("div");
    slot.className = "slot";
    slot.title = link.url;

    var art;
    if (link.icon) {
      art = document.createElement("img");
      art.src = link.icon;
      art.alt = "";
    } else {
      art = document.createElement("div");
      art.className = "mono";
      art.textContent = initial(link);
    }
    slot.appendChild(art);

    var name = document.createElement("div");
    name.className = "name";
    name.textContent = link.title || link.url;
    slot.appendChild(name);

    var pen = document.createElement("div");
    pen.className = "pen";
    pen.textContent = "✎";
    pen.addEventListener("click", function (event) {
      event.stopPropagation();
      openSheet(link);
    });
    slot.appendChild(pen);

    slot.addEventListener("click", function (event) {
      post({ action: "open", id: link.id, background: event.metaKey === true, activate: event.shiftKey === true });
    });
    slot.addEventListener("auxclick", function (event) {
      if (event.button !== 1) return;
      event.preventDefault();
      post({ action: "open", id: link.id, background: true, activate: event.shiftKey === true });
    });
    return slot;
  }

  function blank() {
    var slot = document.createElement("div");
    slot.className = "slot empty";
    slot.textContent = "+";
    slot.addEventListener("click", function () { openSheet(null); });
    return slot;
  }

  function render(next) {
    if (next) state = next;
    grid.textContent = "";
    var links = state.links || [];
    for (var i = 0; i < links.length; i++) grid.appendChild(tile(links[i]));
    // One trailing "+" only — a wall of empty boxes is louder than the page
    // it is sitting on.
    if (links.length < state.slots) grid.appendChild(blank());
    // The count is what the section has left to say once it is folded shut.
    count.textContent = links.length ? String(links.length) : "";
    collapse(state.collapsed === true);
  }

  function collapse(shut) {
    if (shut) section.setAttribute("data-collapsed", "");
    else section.removeAttribute("data-collapsed");
    head.setAttribute("aria-expanded", shut ? "false" : "true");
  }

  head.addEventListener("click", function () {
    var shut = !section.hasAttribute("data-collapsed");
    collapse(shut);
    state.collapsed = shut;
    post({ action: "collapse", value: shut });
  });

  function openSheet(link) {
    editingID = link ? link.id : null;
    heading.textContent = link ? "Edit shortcut" : "Add a shortcut";
    urlField.value = link ? link.url : "";
    titleField.value = link ? link.title : "";
    errLine.textContent = "";
    dropButton.hidden = !link;
    sheet.setAttribute("data-open", "");
    // The ⌘L HUD owns the keyboard while the start page is up; ask for it back,
    // then take focus once its dismissal animation has finished.
    post({ action: "editing", value: true });
    urlField.focus();
    setTimeout(function () { urlField.focus(); urlField.select(); }, 240);
  }

  function closeSheet() {
    sheet.removeAttribute("data-open");
    editingID = null;
    post({ action: "editing", value: false });
  }

  // The sheet is left open here on purpose — the app has the last word on
  // whether the address is usable, and it answers with accept() or reject().
  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var address = urlField.value.trim();
    if (!address) { errLine.textContent = "An address is required."; urlField.focus(); return; }
    errLine.textContent = "";
    post({ action: "save", id: editingID, url: address, title: titleField.value.trim() });
  });
  document.getElementById("cancel").addEventListener("click", closeSheet);
  dropButton.addEventListener("click", function () {
    if (editingID) post({ action: "remove", id: editingID });
    closeSheet();
  });
  sheet.addEventListener("click", function (event) { if (event.target === sheet) closeSheet(); });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && sheet.hasAttribute("data-open")) {
      event.preventDefault();
      closeSheet();
    }
  });

  window.chromelessQuickAccess = {
    render: render,
    // The app skips a refresh while the sheet is up, so an icon landing
    // mid-edit cannot wipe out what is being typed.
    isEditing: function () { return sheet.hasAttribute("data-open"); },
    // The shortcut is saved: shut the sheet, then ask for the repaint that was
    // skipped for exactly that reason a moment ago.
    accept: function () { closeSheet(); post({ action: "ready" }); },
    reject: function (text) { errLine.textContent = text; urlField.focus(); }
  };
  render(null);
})();
</script>
</body></html>
"""#

func startPageHTML() -> String {
    startPageTemplate.replacingOccurrences(of: "__QUICK_ACCESS__", with: quickAccessStore.payloadJSON)
}

// MARK: - Views

final class BrowserWebView: WKWebView {
    // Set by the owning window controller. Fed by `AuxClickRouter` for a
    // middle-click, and by `openLinkInNewTab` for a ⌘-click.
    var onOpenLinkInNewTab: ((URL, _ background: Bool) -> Void)?
    // Fed by `AdBlockPickerRouter` once the element picker has a selector, or
    // nil when the element could not be named safely.
    var onPickedSelector: ((String?) -> Void)?
    // Fed by `QuickAccessRouter` when the start page opens, saves, or drops a
    // shortcut. Bare Esc deliberately does nothing here: it used to jump back
    // to the start page, which threw away whatever was typed into the page.
    var onQuickAccess: ((BrowserWebView, [String: Any]) -> Void)?

    // ⌘ is overloaded: ⌘-drag moves the window, ⌘-click opens the link under
    // the cursor in a new tab. Which one it is is not knowable at mouse-down,
    // so the press is held until the pointer either moves or comes back up.
    // Mouse buttons 4/5 go back/forward.
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }
        let start = event.locationInWindow
        var dragged = false
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                            timeout: .infinity, mode: .eventTracking) { moved, stop in
            guard let moved else { stop.pointee = true; return }
            if moved.type == .leftMouseDragged {
                let p = moved.locationInWindow
                // Same 4pt slop the tab drag uses, so a shaky hand still clicks.
                guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
                dragged = true
            }
            stop.pointee = true
        }
        if dragged {
            window?.performDrag(with: event)
        } else {
            openLinkInNewTab(at: convert(start, from: nil),
                             background: !event.modifierFlags.contains(.shift))
        }
    }

    // The page never sees this click — it was swallowed above — so the link has
    // to be found by asking the document what sits at that point. Only the main
    // frame is searched; a ⌘-click inside an iframe finds nothing. Middle-click
    // has no such limit, since it is handled by a script injected into every
    // frame.
    private func openLinkInNewTab(at point: NSPoint, background: Bool) {
        // elementFromPoint wants CSS pixels down from the top-left of the
        // viewport. WKWebView is flipped, so the converted point already counts
        // downwards; only the zoom has to be divided out.
        let scale = pageZoom * magnification
        guard scale > 0, isFlipped else { return }
        let x = point.x / scale
        let y = point.y / scale
        evaluateJavaScript("""
        (function () {
          var n = document.elementFromPoint(\(x), \(y));
          while (n && n.nodeType === 1) {
            if (n.tagName === "A" && n.href) return n.href;
            n = n.parentNode;
          }
          return null;
        })();
        """) { [weak self] result, _ in
            guard let href = result as? String, let url = URL(string: href) else { return }
            self?.onOpenLinkInNewTab?(url, background)
        }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 3, canGoBack { goBack(); return }
        if event.buttonNumber == 4, canGoForward { goForward(); return }
        super.otherMouseUp(with: event)
    }
}

final class LayoutReportingView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

// The profile chip. It used to pass clicks through to the page; now it is a
// button that opens the profile picker, so it takes its own clicks.
final class ProfileChipView: NSVisualEffectView {
    var onClick: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { animator().alphaValue = 1.0 }
    override func mouseExited(with event: NSEvent) { animator().alphaValue = 0.82 }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Tabs

// WebKit does not treat a middle-click on a link as a request for a new window
// — it never calls `createWebViewWith` and just navigates the current frame,
// which is worse than doing nothing. So the page has to be taught: cancel the
// default action and hand the href back for a background tab.
private let auxClickScript = """
(function () {
  function anchor(node) {
    while (node && node.nodeType === 1) {
      if (node.tagName === "A" && node.href) return node;
      node = node.parentNode;
    }
    return null;
  }
  function swallow(e) {
    if (e.button === 1 && anchor(e.target)) e.preventDefault();
  }
  // The navigation is suppressed on the way down and the href reported on the
  // way up, so the gesture only counts once the button is actually released.
  document.addEventListener("mousedown", swallow, true);
  document.addEventListener("auxclick", function (e) {
    if (e.button !== 1) return;
    var a = anchor(e.target);
    if (!a) return;
    e.preventDefault();
    e.stopPropagation();
    window.webkit.messageHandlers.chromelessAuxClick.postMessage(a.href);
  }, true);
})();
"""

// One shared handler for every web view: it routes by the message's own web
// view, so it never needs to know which window or profile the page belongs to.
final class AuxClickRouter: NSObject, WKScriptMessageHandler {
    static let shared = AuxClickRouter()
    static let messageName = "chromelessAuxClick"

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? BrowserWebView,
              let href = message.body as? String,
              let url = URL(string: href) else { return }
        webView.onOpenLinkInNewTab?(url, true)
    }
}

func makeWebConfiguration(for profile: BrowserProfile) -> WKWebViewConfiguration {
    let conf = WKWebViewConfiguration()
    conf.websiteDataStore = profileStore.websiteDataStore(for: profile)
    conf.preferences.isElementFullscreenEnabled = true
    conf.mediaTypesRequiringUserActionForPlayback = []
    conf.allowsAirPlayForMediaPlayback = true
    conf.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
    conf.userContentController.add(AuxClickRouter.shared, name: AuxClickRouter.messageName)
    conf.userContentController.add(AdBlockPickerRouter.shared, name: AdBlockPickerRouter.messageName)
    conf.userContentController.add(QuickAccessRouter.shared, name: QuickAccessRouter.messageName)
    conf.userContentController.addUserScript(WKUserScript(
        source: auxClickScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    if !hasPasskeyEntitlement {
        let hideWebAuthn = WKUserScript(
            source: """
            (function () {
              try {
                delete window.PublicKeyCredential;
                delete window.AuthenticatorResponse;
                delete window.AuthenticatorAttestationResponse;
                delete window.AuthenticatorAssertionResponse;
              } catch (e) {}
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false)
        conf.userContentController.addUserScript(hideWebAuthn)
    }
    return conf
}

// One tab: a web view plus the page state that used to live on the window
// controller back when a window held exactly one page.
final class Tab {
    let webView: BrowserWebView
    var onStartPage = false
    var lastProgress: CGFloat = 0
    var observations: [NSKeyValueObservation] = []

    init(webView: BrowserWebView) { self.webView = webView }

    var displayTitle: String {
        if onStartPage { return "chromeless" }
        let t = webView.title ?? ""
        if !t.isEmpty { return t }
        return webView.url?.host ?? "New Tab"
    }

    func teardown() {
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }
}

final class TabItemView: NSView {
    // The callbacks hand back the view rather than an index, so TabBarView can
    // read `index` at call time. Baking the index into the closure only worked
    // while every item was thrown away and rebuilt after each change.
    var onSelect: ((TabItemView) -> Void)?
    var onClose: ((TabItemView) -> Void)?
    var onDragBegin: ((TabItemView, NSEvent) -> Void)?

    var index = 0

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?
    private var middleDownInside = false

    var isActive = false { didSet { applyStyle(); needsLayout = true } }
    var title = "" {
        didSet {
            label.stringValue = title
            toolTip = title
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 9, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        addSubview(closeButton)

        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func closeClicked() { onClose?(self) }

    private func applyStyle() {
        layer?.backgroundColor = isActive
            ? NSColor.white.withAlphaComponent(0.14).cgColor
            : (hovering ? NSColor.white.withAlphaComponent(0.07).cgColor : NSColor.clear.cgColor)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        closeButton.isHidden = false
        applyStyle()
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        closeButton.isHidden = true
        applyStyle()
        needsLayout = true
    }

    // Claim the press before it reaches the title label, so the middle-click
    // bounds check below is against the tab's own geometry. The close button is
    // the one exception, since it needs its own tracking.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return self
    }

    // Selecting on press is what every browser does, so it happens before the
    // drag is even considered; the bar decides afterwards whether the gesture
    // turns into a reorder.
    override func mouseDown(with event: NSEvent) {
        onSelect?(self)
        onDragBegin?(self, event)
    }

    // Middle-click closes, but only on release and only if the cursor never
    // left the tab — sliding off before letting go cancels, the way it does for
    // every other destructive click on macOS.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middleDownInside = true
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, middleDownInside else {
            return super.otherMouseUp(with: event)
        }
        middleDownInside = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClose?(self) }
    }

    override func layout() {
        super.layout()
        let b = bounds
        closeButton.frame = NSRect(x: b.width - 20, y: (b.height - 16) / 2, width: 16, height: 16)
        let labelRight: CGFloat = closeButton.isHidden ? 8 : 22
        label.frame = NSRect(x: 9, y: (b.height - 15) / 2,
                             width: max(0, b.width - 9 - labelRight), height: 15)
    }
}

final class TabBarView: NSVisualEffectView {
    static let height: CGFloat = 34
    // The traffic lights are hidden but appear on hover over the top-left
    // corner. Without this inset they would draw on top of the first tab.
    static let trafficLightInset: CGFloat = 78

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onReorder: ((Int, Int) -> Void)?

    private var items: [TabItemView] = []
    private let addButton = NSButton()
    private var chipWidth: CGFloat = 0
    // Set only while a drag is live. `layout()` leaves this item alone; without
    // that, any layout pass mid-gesture snaps it back to its slot.
    private var dragItem: TabItemView?
    private var dragToken = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true

        addButton.isBordered = false
        addButton.bezelStyle = .inline
        addButton.title = "+"
        addButton.font = .systemFont(ofSize: 16, weight: .medium)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "New Tab (⌘T)"
        addButton.target = self
        addButton.action = #selector(addClicked)
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func addClicked() { onNewTab?() }

    // With the tab bar up, the window is `isMovable = false` (see `refreshTabs`),
    // so the empty part of the strip has to move the window by hand. Presses on
    // a tab never reach here — items are subviews and take their own events.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    // Middle-clicking the strip itself opens a tab. Items are subviews, so a
    // middle-click that lands on a tab is hit-tested there and never gets here.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        onNewTab?()
    }

    // Items are reused across rebuilds rather than recreated. A drag holds on
    // to the view it is moving, and selecting a tab rebuilds the bar, so tearing
    // the views down would kill the gesture on its first frame.
    func rebuild(titles: [String], activeIndex: Int) {
        while items.count > titles.count {
            let gone = items.removeLast()
            if gone === dragItem { dragItem = nil }
            gone.removeFromSuperview()
        }
        while items.count < titles.count {
            let item = TabItemView(frame: .zero)
            item.onSelect = { [weak self] in self?.onSelect?($0.index) }
            item.onClose = { [weak self] in self?.onClose?($0.index) }
            item.onDragBegin = { [weak self] in self?.beginDrag($0, with: $1) }
            addSubview(item, positioned: .below, relativeTo: addButton)
            items.append(item)
        }
        for (index, item) in items.enumerated() {
            item.index = index
            item.title = titles[index]
            item.isActive = index == activeIndex
        }
        needsLayout = true
    }

    func update(titleAt index: Int?, to title: String) {
        guard let index, items.indices.contains(index) else { return }
        items[index].title = title
    }

    func setChipWidth(_ width: CGFloat) {
        guard width != chipWidth else { return }
        chipWidth = width
        needsLayout = true
    }

    // Slot geometry, shared by `layout()` and the drag loop so a dragged tab
    // lands on exactly the position layout would have given it.
    private var tabPitch: CGFloat {
        let addW: CGFloat = 26
        let available = max(0, bounds.width - Self.trafficLightInset - (chipWidth + 18) - addW - 8)
        return min(190, max(90, available / CGFloat(max(1, items.count))))
    }

    private func slotFrame(_ index: Int) -> NSRect {
        NSRect(x: Self.trafficLightInset + tabPitch * CGFloat(index), y: 3,
               width: max(40, tabPitch - 3), height: bounds.height - 6)
    }

    override func layout() {
        super.layout()
        for (index, item) in items.enumerated() where item !== dragItem {
            item.frame = slotFrame(index)
        }
        let addW: CGFloat = 26
        let rightReserve = chipWidth + 18
        let x = Self.trafficLightInset + tabPitch * CGFloat(items.count)
        addButton.frame = NSRect(
            x: min(x + 2, max(Self.trafficLightInset, bounds.width - rightReserve - addW)),
            y: (bounds.height - 22) / 2, width: addW, height: 22)
    }

    // MARK: Drag to reorder

    private func settle(_ index: Int, of item: TabItemView) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            item.animator().frame = slotFrame(index)
        }
    }

    private func beginDrag(_ item: TabItemView, with event: NSEvent) {
        guard let window, items.count > 1 else { return }
        dragToken += 1
        let token = dragToken
        let start = convert(event.locationInWindow, from: nil)
        let grabOffset = start.x - item.frame.origin.x
        let startIndex = items.firstIndex(of: item) ?? item.index
        let originalOrder = items
        var currentIndex = startIndex
        var live = false
        var cancelled = false

        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                           timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { stop.pointee = true; return }
            switch event.type {
            case .keyDown:
                guard event.keyCode == 53 else { return } // Esc
                cancelled = true
                self.items = originalOrder
                stop.pointee = true

            case .leftMouseDragged:
                let p = self.convert(event.locationInWindow, from: nil)
                if !live {
                    // Below this the gesture is still a click, not a drag.
                    guard abs(p.x - start.x) >= 4 else { return }
                    live = true
                    self.dragItem = item
                    self.addSubview(item, positioned: .below, relativeTo: self.addButton)
                }
                let pitch = self.tabPitch
                let maxX = Self.trafficLightInset + pitch * CGFloat(self.items.count - 1)
                item.frame.origin.x = min(max(p.x - grabOffset, Self.trafficLightInset), maxX)

                let raw = Int(((item.frame.origin.x - Self.trafficLightInset) / pitch).rounded())
                let target = min(max(raw, 0), self.items.count - 1)
                guard target != currentIndex else { return }
                self.items.remove(at: currentIndex)
                self.items.insert(item, at: target)
                currentIndex = target
                for (index, other) in self.items.enumerated() where other !== item {
                    self.settle(index, of: other)
                }

            case .leftMouseUp:
                stop.pointee = true

            default:
                break
            }
        }

        guard live else { return }
        let finalIndex = cancelled ? startIndex : currentIndex
        // `dragItem` stays set until the settle animation finishes, so the
        // relayout that `onReorder` triggers does not yank the tab into place
        // and cut the animation short.
        settle(finalIndex, of: item)
        // Keyed on the drag, not the view: starting a second drag on the same tab
        // inside the settle window would otherwise clear `dragItem` underneath it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.dragToken == token else { return }
            self.dragItem = nil
            self.needsLayout = true
        }
        if cancelled {
            for (index, other) in items.enumerated() where other !== item {
                settle(index, of: other)
            }
        } else if finalIndex != startIndex {
            onReorder?(startIndex, finalIndex)
        }
    }
}

// MARK: - Browser window

final class BrowserWindowController: NSWindowController, NSWindowDelegate,
    WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSMenuItemValidation {

    private(set) var tabs: [Tab] = []
    private(set) var activeIndex = 0
    private let profile: BrowserProfile
    private let tabBar = TabBarView()
    private let progressBar = NSView()
    private let hud = NSVisualEffectView()
    private let hudField = NSTextField()
    private let toastView = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private let profileBadge = ProfileChipView()
    private let profileLabel = NSTextField(labelWithString: "")
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var snapJob: SnapJob?
    private var toastHide: DispatchWorkItem?
    private let downloadsPanel = DownloadsPanelView()
    private var downloadsPanelPinned = false
    private var downloadsHide: DispatchWorkItem?
    private var downloadsObservers: [NSObjectProtocol] = []
    private var quickAccessObserver: NSObjectProtocol?
    // ⌥ is read when the navigation is still an action, because a response
    // download arrives a round trip later, by which time the key is released.
    private var pendingDownloadWantsPanel = false
    var profileID: String { profile.id }
    var onClose: (() -> Void)?

    // Every existing menu action, HUD commit, snapshot, and download path
    // reaches the page through `webView`, so pointing it at the active tab
    // keeps all of them working untouched.
    var activeTab: Tab { tabs[activeIndex] }
    var webView: BrowserWebView { tabs[activeIndex].webView }
    private var tabBarVisible: Bool { tabs.count > 1 }
    private var tabBarHeight: CGFloat { tabBarVisible ? TabBarView.height : 0 }

    init(profile: BrowserProfile, url: URL?, size: NSSize?, snap: SnapJob?, isPrimary: Bool) {
        self.profile = profile
        tabs = [Tab(webView: BrowserWebView(
            frame: .zero, configuration: makeWebConfiguration(for: profile)))]
        snapJob = snap

        let contentSize = size ?? NSSize(width: 1160, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init(window: window)

        window.title = "Chromeless - \(profile.name)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 220)
        window.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        setTrafficLights(visible: false)

        let container = LayoutReportingView(frame: NSRect(origin: .zero, size: contentSize))
        container.onLayout = { [weak self] in self?.layoutOverlays() }
        window.contentView = container

        configure(tabs[0])
        tabs[0].webView.frame = container.bounds
        container.addSubview(tabs[0].webView)

        buildOverlays(in: container)

        window.center()
        if isPrimary && snap == nil {
            window.setFrameUsingName("ChromelessMain-\(profile.id)")
            window.setFrameAutosaveName("ChromelessMain-\(profile.id)")
        } else if let key = NSApp.keyWindow {
            window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 30, y: key.frame.maxY - 30))
        }
        if let size { window.setContentSize(size) }

        installMouseMonitor()
        installKeyMonitor()

        if let url { navigate(to: url) } else { loadStartPage() }
        if snap == nil && !profileStore.usesPersistentProfileStores {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showToast("Profiles are private on macOS 13; persistent profiles need macOS 14")
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Tabs

    private func configure(_ tab: Tab) {
        let wv = tab.webView
        wv.autoresizingMask = [.width, .height]
        wv.onQuickAccess = { [weak self] source, body in self?.handleQuickAccess(body, from: source) }
        wv.onOpenLinkInNewTab = { [weak self] url, background in
            _ = self?.addTab(url: url, activate: !background)
        }
        wv.onPickedSelector = { [weak self] selector in
            guard let self else { return }
            guard let selector else {
                self.showToast("That element can’t be targeted safely")
                return
            }
            // The rule is compiled by the time this runs, but the page in front
            // of the user was laid out before it existed.
            self.showToast("Hiding \(selector)")
            self.reloadPage(nil)
        }
        adBlockManager.register(wv)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.underPageBackgroundColor = NSColor(calibratedWhite: 0.04, alpha: 1)
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        observe(tab)
    }

    // `configuration` is non-nil only when WebKit hands us one for window.open
    // or target=_blank; in that case WebKit drives the load itself.
    @discardableResult
    func addTab(url: URL?, configuration: WKWebViewConfiguration? = nil, activate: Bool = true) -> Tab {
        let conf = configuration ?? makeWebConfiguration(for: profile)
        let tab = Tab(webView: BrowserWebView(frame: .zero, configuration: conf))
        configure(tab)
        tabs.append(tab)
        if activate { activeIndex = tabs.count - 1 }
        refreshTabs()
        if configuration == nil {
            if let url { load(url, in: tab) } else { loadStartPage(in: tab) }
        }
        return tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        refreshTabs()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Closing the only tab closes the window, so ⌘W keeps its old meaning.
        if tabs.count == 1 { window?.performClose(nil); return }
        let tab = tabs.remove(at: index)
        tab.teardown()
        if activeIndex >= tabs.count {
            activeIndex = tabs.count - 1
        } else if index < activeIndex {
            activeIndex -= 1
        }
        refreshTabs()
    }

    // Reordering only permutes the array; no web view is created, destroyed, or
    // reparented, so the page being viewed never notices.
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        tabs.insert(tabs.remove(at: from), at: to)
        // Keep whichever tab was active active, wherever it ended up.
        if activeIndex == from {
            activeIndex = to
        } else if from < activeIndex, activeIndex <= to {
            activeIndex -= 1
        } else if to <= activeIndex, activeIndex < from {
            activeIndex += 1
        }
        refreshTabs()
    }

    private func refreshTabs() {
        guard let container = window?.contentView else { return }
        for tab in tabs where tab !== activeTab && tab.webView.superview != nil {
            tab.webView.removeFromSuperview()
        }
        if activeTab.webView.superview == nil {
            container.addSubview(activeTab.webView, positioned: .below, relativeTo: tabBar)
        }
        tabBar.rebuild(titles: tabs.map(\.displayTitle), activeIndex: activeIndex)
        tabBar.isHidden = !tabBarVisible
        // The tab bar sits in the titlebar strip, which the WindowServer claims
        // as a window-drag region from outside this process. No view-level
        // property gets it back — `mouseDownCanMoveWindow` is simply ignored
        // there — so a press on a tab slides the window instead of the tab.
        // Clearing `isMovable` is the one thing that stops it. `performDrag` is
        // unaffected by the flag, so ⌘-drag and the empty strip still move the
        // window; with a single tab there is no bar and the strip behaves as it
        // always has.
        window?.isMovable = !tabBarVisible
        // Lay out now rather than next frame, so a switch never paints one
        // frame of tabs still sitting at their old positions.
        tabBar.layoutSubtreeIfNeeded()
        syncWindowTitle()
        let p = activeTab.lastProgress
        progressBar.alphaValue = (p > 0 && p < 1) ? 1 : 0
        layoutOverlays()
        // The HUD is the address bar for the page you are on, so it must not
        // survive a tab switch carrying the previous tab's URL.
        if hud.isHidden {
            window?.makeFirstResponder(activeTab.webView)
        } else {
            hideHUD()
        }
    }

    private func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    private func syncWindowTitle() {
        let t = activeTab.webView.title ?? ""
        window?.title = "\(t.isEmpty ? "Chromeless" : t) - \(profile.name)"
    }

    // MARK: Chrome (what little there is)

    private func setTrafficLights(visible: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.isHidden = !visible
        }
    }

    private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .mouseMoved {
                // Reveal the traffic lights only when hovering the top-left corner.
                guard let contentView = self.window?.contentView else { return event }
                let p = event.locationInWindow
                let nearCorner = p.y > contentView.bounds.height - 44 && p.x < 96
                self.setTrafficLights(visible: self.isFullScreen || nearCorner)
            } else if !self.hud.isHidden {
                let p = self.window!.contentView!.convert(event.locationInWindow, from: nil)
                if !self.hud.frame.contains(p) { self.hideHUD() }
            }
            return event
        }
    }

    // ⌃Tab cannot be a menu key equivalent on macOS, so it is caught here —
    // and F12 lives here too, so the menu can advertise the Mac-native ⌥⌘I
    // while the Chrome/Windows reflex still works.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.keyCode == 111, !event.modifierFlags.contains(.command) {
                self.toggleWebInspector(nil)
                return nil
            }
            guard event.modifierFlags.contains(.control), event.keyCode == 48 else { return event }
            if event.modifierFlags.contains(.shift) {
                self.showPreviousTab(nil)
            } else {
                self.showNextTab(nil)
            }
            return nil
        }
    }

    private func buildOverlays(in container: NSView) {
        tabBar.onSelect = { [weak self] i in self?.selectTab(at: i) }
        tabBar.onClose = { [weak self] i in self?.closeTab(at: i) }
        tabBar.onNewTab = { [weak self] in self?.addTab(url: nil) }
        tabBar.onReorder = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabBar.isHidden = true
        container.addSubview(tabBar)

        progressBar.wantsLayer = true
        progressBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        progressBar.alphaValue = 0
        container.addSubview(progressBar)

        hud.material = .hudWindow
        hud.blendingMode = .withinWindow
        hud.state = .active
        hud.wantsLayer = true
        hud.layer?.cornerRadius = 26
        hud.layer?.cornerCurve = .continuous
        hud.layer?.masksToBounds = true
        hud.layer?.borderWidth = 1
        hud.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        hud.isHidden = true
        hud.alphaValue = 0
        hudField.isBezeled = false
        hudField.isBordered = false
        hudField.drawsBackground = false
        hudField.focusRingType = .none
        hudField.font = .systemFont(ofSize: 16)
        hudField.textColor = .labelColor
        hudField.placeholderString = "Search or enter address"
        hudField.usesSingleLineMode = true
        hudField.cell?.isScrollable = true
        hudField.cell?.wraps = false
        hudField.delegate = self
        hud.addSubview(hudField)
        container.addSubview(hud)

        toastView.material = .hudWindow
        toastView.blendingMode = .withinWindow
        toastView.state = .active
        toastView.wantsLayer = true
        toastView.layer?.cornerRadius = 17
        toastView.layer?.cornerCurve = .continuous
        toastView.layer?.masksToBounds = true
        toastView.isHidden = true
        toastView.alphaValue = 0
        toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .labelColor
        toastView.addSubview(toastLabel)
        container.addSubview(toastView)

        profileBadge.material = .hudWindow
        profileBadge.blendingMode = .withinWindow
        profileBadge.state = .active
        profileBadge.wantsLayer = true
        profileBadge.layer?.cornerRadius = 12
        profileBadge.layer?.cornerCurve = .continuous
        profileBadge.layer?.masksToBounds = true
        profileBadge.alphaValue = 0.82
        profileLabel.stringValue = profile.name
        profileLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        profileLabel.textColor = .labelColor
        profileLabel.lineBreakMode = .byTruncatingTail
        profileBadge.toolTip = "Profile — click to switch"
        profileBadge.onClick = { [weak self] in
            guard let self else { return }
            (NSApp.delegate as? AppDelegate)?.presentProfilePicker(from: self)
        }
        profileBadge.addSubview(profileLabel)
        container.addSubview(profileBadge)

        downloadsPanel.onClose = { [weak self] in self?.hideDownloadsPanel() }
        container.addSubview(downloadsPanel)
        observeDownloads()
        observeQuickAccess()
    }

    // MARK: Downloads panel

    private func observeDownloads() {
        let center = NotificationCenter.default
        downloadsObservers = [
            center.addObserver(forName: .downloadsDidChange, object: nil, queue: .main) {
                [weak self] _ in self?.downloadsChanged()
            },
            center.addObserver(forName: .downloadsMessage, object: nil, queue: .main) {
                [weak self] note in
                guard let self, self.window?.isKeyWindow == true,
                      let text = note.userInfo?["text"] as? String else { return }
                self.showToast(text)
            },
        ]
    }

    private func downloadsChanged() {
        downloadsPanel.refresh()
        layoutOverlays()
        if downloadManager.hasActiveDownloads {
            downloadsHide?.cancel()
            downloadsHide = nil
        } else if !downloadsPanel.isHidden && !downloadsPanelPinned {
            scheduleDownloadsHide()
        }
    }

    private func showDownloadsPanel(pinned: Bool) {
        if pinned { downloadsPanelPinned = true }
        downloadsHide?.cancel()
        downloadsHide = nil
        downloadsPanel.refresh()
        layoutOverlays()
        guard downloadsPanel.isHidden || downloadsPanel.alphaValue < 1 else { return }
        downloadsPanel.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            downloadsPanel.animator().alphaValue = 1
        }
    }

    private func hideDownloadsPanel() {
        downloadsPanelPinned = false
        downloadsHide?.cancel()
        downloadsHide = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.downloadsPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.downloadsPanel.alphaValue == 0 else { return }
            self.downloadsPanel.isHidden = true
        }
    }

    // Linger for a moment after the last transfer lands, and keep lingering
    // while the pointer is still in the panel reaching for Reveal.
    private func scheduleDownloadsHide() {
        downloadsHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.downloadsPanelPinned,
                  !downloadManager.hasActiveDownloads else { return }
            if self.downloadsPanel.pointerInside {
                self.scheduleDownloadsHide()
                return
            }
            self.hideDownloadsPanel()
        }
        downloadsHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @objc func toggleDownloadsPanel(_ sender: Any?) {
        if downloadsPanel.isHidden || downloadsPanel.alphaValue < 1 {
            showDownloadsPanel(pinned: true)
        } else {
            hideDownloadsPanel()
        }
    }

    private func layoutOverlays() {
        guard let contentView = window?.contentView else { return }
        let b = contentView.bounds

        let barH = tabBarHeight
        tabBar.isHidden = !tabBarVisible
        tabBar.frame = NSRect(x: 0, y: b.height - barH, width: b.width, height: barH)
        activeTab.webView.frame = NSRect(x: 0, y: 0, width: b.width, height: b.height - barH)

        let hudW = min(620, max(280, b.width - 48))
        let hudH: CGFloat = 52
        hud.frame = NSRect(x: (b.width - hudW) / 2, y: b.height - barH - hudH - 84,
                           width: hudW, height: hudH)
        hudField.frame = NSRect(x: 20, y: (hudH - 22) / 2, width: hudW - 40, height: 22)

        toastLabel.sizeToFit()
        let ts = toastLabel.frame.size
        let tw = ts.width + 32
        let th: CGFloat = 34
        toastView.frame = NSRect(x: (b.width - tw) / 2, y: 28, width: tw, height: th)
        toastLabel.frame = NSRect(x: 16, y: (th - ts.height) / 2, width: ts.width, height: ts.height)

        // Bottom-right, and never taller than the window leaves room for.
        let dlW = min(DownloadsPanelView.width, max(240, b.width - 40))
        let dlH = min(downloadsPanel.preferredHeight, max(120, b.height - barH - 40))
        downloadsPanel.frame = NSRect(x: b.width - dlW - 20, y: 20, width: dlW, height: dlH)

        let profileMaxW = min(180, max(90, b.width * 0.34))
        let profileTextW = min(profileMaxW - 22, profileLabel.intrinsicContentSize.width)
        let profileW = max(72, profileTextW + 22)
        let profileH: CGFloat = 24

        // One chip, two homes: docked in the tab bar when it is up, floating in
        // the corner when it is not.
        if tabBarVisible {
            if profileBadge.superview !== tabBar {
                profileBadge.removeFromSuperview()
                tabBar.addSubview(profileBadge)
            }
            tabBar.setChipWidth(profileW)
            profileBadge.frame = NSRect(
                x: b.width - profileW - 12,
                y: (barH - profileH) / 2,
                width: profileW,
                height: profileH)
        } else {
            if profileBadge.superview !== contentView {
                profileBadge.removeFromSuperview()
                contentView.addSubview(profileBadge)
            }
            let topInset: CGFloat = isFullScreen ? 18 : 12
            profileBadge.frame = NSRect(
                x: b.width - profileW - 14,
                y: b.height - profileH - topInset,
                width: profileW,
                height: profileH)
        }
        profileLabel.frame = NSRect(
            x: 11,
            y: (profileH - 14) / 2,
            width: profileW - 22,
            height: 14)

        progressBar.frame = NSRect(x: 0, y: b.height - barH - 2,
                                   width: b.width * activeTab.lastProgress, height: 2)
    }

    private func observe(_ tab: Tab) {
        tab.observations = [
            tab.webView.observe(\.estimatedProgress, options: [.new]) { [weak self, weak tab] wv, _ in
                guard let self, let tab else { return }
                tab.lastProgress = CGFloat(wv.estimatedProgress)
                if tab === self.activeTab { self.progressChanged(wv.estimatedProgress) }
            },
            tab.webView.observe(\.title) { [weak self, weak tab] _, _ in
                guard let self, let tab else { return }
                self.tabBar.update(titleAt: self.tabs.firstIndex { $0 === tab }, to: tab.displayTitle)
                if tab === self.activeTab { self.syncWindowTitle() }
            },
            tab.webView.observe(\.url) { [profile] wv, _ in
                if let u = wv.url, u.scheme == "https" || u.scheme == "http" {
                    profileStore.recordVisit(u, for: profile)
                }
            },
        ]
    }

    private func progressChanged(_ progress: Double) {
        activeTab.lastProgress = CGFloat(progress)
        if let width = window?.contentView?.bounds.width {
            progressBar.frame.size.width = width * activeTab.lastProgress
        }
        if progress >= 1.0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                progressBar.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.activeTab.lastProgress = 0
                self?.layoutOverlays()
            })
        } else {
            progressBar.alphaValue = 1
        }
    }

    // MARK: Navigation

    func load(_ url: URL, in tab: Tab) {
        tab.onStartPage = false
        if url.isFileURL {
            tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            tab.webView.load(URLRequest(url: url))
        }
    }

    func loadStartPage(in tab: Tab) {
        tab.onStartPage = true
        tab.webView.loadHTMLString(startPageHTML(), baseURL: nil)
        tabBar.update(titleAt: tabs.firstIndex { $0 === tab }, to: tab.displayTitle)
    }

    func navigate(to url: URL) { load(url, in: activeTab) }

    func loadStartPage() {
        loadStartPage(in: activeTab)
        if let job = snapJob {
            snapJob = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.runSnapJob(job)
            }
        }
    }

    // MARK: Quick access

    private func observeQuickAccess() {
        quickAccessObserver = NotificationCenter.default.addObserver(
            forName: .quickAccessDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.refreshQuickAccess()
            }
    }

    // Every start page in the window is repainted, not just the front one, and
    // every other window does the same off the notification — a shortcut saved
    // here has to exist everywhere it is on screen. The sheet being open is the
    // one exception: an icon arriving mid-edit must not blow away the typing.
    private func refreshQuickAccess() {
        for tab in tabs where tab.onStartPage { render(into: tab.webView) }
    }

    private func render(into webView: BrowserWebView) {
        webView.evaluateJavaScript("""
        (function () {
          var qa = window.chromelessQuickAccess;
          if (qa && !qa.isEditing()) qa.render(\(quickAccessStore.payloadJSON));
        })();
        """)
    }

    /// Calls one method on the start page's bridge, and does nothing at all if
    /// the page in that view has since been navigated away from.
    private func reply(to webView: BrowserWebView, _ call: String) {
        webView.evaluateJavaScript(
            "window.chromelessQuickAccess && window.chromelessQuickAccess.\(call);")
    }

    private func handleQuickAccess(_ body: [String: Any], from webView: BrowserWebView) {
        switch body["action"] as? String {
        case "open":
            guard let id = body["id"] as? String,
                  let link = quickAccessStore.link(id: id),
                  let url = URL(string: link.url) else { return }
            if body["background"] as? Bool == true {
                addTab(url: url, activate: body["activate"] as? Bool == true)
            } else {
                guard let tab = tab(for: webView) else { return }
                load(url, in: tab)
            }

        // The sheet stays open until this comes back, so a rejected address can
        // be corrected instead of being silently swallowed.
        case "save":
            let raw = (body["url"] as? String) ?? ""
            guard let url = smartURL(raw), !url.isFileURL else {
                reply(to: webView, "reject('That address doesn\\'t look right.')")
                return
            }
            let id = body["id"] as? String
            guard quickAccessStore.save(id: id, title: (body["title"] as? String) ?? "", url: url) != nil else {
                reply(to: webView, "reject('All \(QuickAccessStore.slotCount) slots are taken.')")
                return
            }
            reply(to: webView, "accept()")

        case "remove":
            guard let id = body["id"] as? String else { return }
            quickAccessStore.remove(id: id)

        // Folded or unfolded is remembered, since the start page is rebuilt
        // from scratch every time it is opened.
        case "collapse":
            quickAccessStore.setCollapsed(body["value"] as? Bool == true)

        case "editing":
            // The HUD floats over the page and holds first responder, so it has
            // to get out of the way before the sheet can be typed into.
            if body["value"] as? Bool == true { hideHUD() }

        // Sent by the page once its sheet is shut. `refreshQuickAccess` skipped
        // this tab while the sheet was open, so this is the repaint it missed.
        case "ready":
            guard let tab = tab(for: webView), tab.onStartPage else { return }
            render(into: webView)

        default:
            break
        }
    }

    // MARK: HUD (the ⌘L address bar)

    func showHUD() {
        if let u = webView.url, !activeTab.onStartPage, u.absoluteString != "about:blank" {
            hudField.stringValue = u.absoluteString
        } else {
            hudField.stringValue = ""
        }
        hud.isHidden = false
        layoutOverlays()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hud.animator().alphaValue = 1
        }
        hudField.selectText(nil)
    }

    func hideHUD() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            self.hud.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.hud.isHidden = true
            self.window?.makeFirstResponder(self.webView)
        })
    }

    private func commitHUD() {
        let text = hudField.stringValue
        hideHUD()
        if let url = smartURL(text) { navigate(to: url) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideHUD(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitHUD(); return true }
        return false
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toastLabel.stringValue = text
        layoutOverlays()
        toastHide?.cancel()
        toastView.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toastView.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self.toastView.animator().alphaValue = 0
            }, completionHandler: { self.toastView.isHidden = true })
        }
        toastHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    // MARK: Snapshots

    private func writePNG(from image: NSImage, to path: String) -> (Int, Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return (cg.width, cg.height)
        } catch {
            return nil
        }
    }

    private func runSnapJob(_ job: SnapJob) {
        DispatchQueue.main.asyncAfter(deadline: .now() + job.wait) { [weak self] in
            guard let self else { exit(3) }
            self.webView.takeSnapshot(with: nil) { image, error in
                guard let image, let dims = self.writePNG(from: image, to: job.path) else {
                    fputs("chromeless: snapshot failed: \(error?.localizedDescription ?? "could not write PNG")\n", stderr)
                    exit(3)
                }
                print("saved \(job.path) (\(dims.0)x\(dims.1) px)")
                exit(0)
            }
        }
    }

    // MARK: Menu actions

    @objc func openLocation(_ sender: Any?) { showHUD() }

    @objc func reloadPage(_ sender: Any?) {
        if activeTab.onStartPage { loadStartPage() } else { webView.reload() }
    }

    @objc func hardReloadPage(_ sender: Any?) {
        if activeTab.onStartPage { loadStartPage() } else { webView.reloadFromOrigin() }
    }

    // WebKit exposes no public way to open the inspector — `isInspectable`
    // only unlocks it for Safari's Develop menu and the context menu. The
    // private `_inspector` handle is what Safari itself drives; every hop is
    // guarded so a rename in a future macOS degrades to a toast, not a crash.
    @objc func toggleWebInspector(_ sender: Any?) {
        guard let inspector = webInspector else {
            showToast("Web Inspector unavailable")
            return
        }
        let action = NSSelectorFromString(isWebInspectorVisible ? "hide" : "show")
        guard inspector.responds(to: action) else {
            showToast("Web Inspector unavailable")
            return
        }
        _ = inspector.perform(action)
    }

    private var webInspector: NSObject? {
        let sel = NSSelectorFromString("_inspector")
        guard webView.responds(to: sel) else { return nil }
        return webView.perform(sel)?.takeUnretainedValue() as? NSObject
    }

    private var isWebInspectorVisible: Bool {
        let sel = NSSelectorFromString("isVisible")
        guard let inspector = webInspector, inspector.responds(to: sel) else { return false }
        return (inspector.value(forKey: "isVisible") as? Bool) ?? false
    }

    @objc func goBackAction(_ sender: Any?) { webView.goBack() }
    @objc func goForwardAction(_ sender: Any?) { webView.goForward() }

    @objc func zoomInPage(_ sender: Any?) { webView.pageZoom = min(webView.pageZoom * 1.1, 5.0) }
    @objc func zoomOutPage(_ sender: Any?) { webView.pageZoom = max(webView.pageZoom / 1.1, 0.25) }
    @objc func resetZoom(_ sender: Any?) { webView.pageZoom = 1.0 }

    @objc func saveSnapshot(_ sender: Any?) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "chromeless \(formatter.string(from: Date())).png"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let path = desktop.appendingPathComponent(name).path
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self else { return }
            if let image, self.writePNG(from: image, to: path) != nil {
                self.showToast("Saved “\(name)” to Desktop")
            } else {
                self.showToast("Snapshot failed")
            }
        }
    }

    @objc func copyPageURL(_ sender: Any?) {
        guard let u = webView.url, u.absoluteString != "about:blank" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u.absoluteString, forType: .string)
        showToast("URL copied")
    }

    @objc func togglePin(_ sender: Any?) {
        guard let window else { return }
        let pinned = window.level == .floating
        window.level = pinned ? .normal : .floating
        showToast(pinned ? "Unpinned" : "Pinned on top")
    }

    @objc func showHelpPage(_ sender: Any?) { loadStartPage() }

    @objc func goHome(_ sender: Any?) { loadStartPage() }

    // MARK: Ad blocking

    @objc func toggleSiteBlocking(_ sender: Any?) {
        guard let url = webView.url, let domain = AdBlockManager.domain(for: url) else {
            showToast("Nothing to allow or block here")
            return
        }
        let blocking = adBlockManager.isBlocking(url)
        showToast(blocking ? "Ads allowed on \(domain)" : "Blocking ads on \(domain)")
        adBlockManager.setBlocking(!blocking, for: url) { [weak self] in
            self?.reloadPage(nil)
        }
    }

    @objc func pickElementToBlock(_ sender: Any?) {
        guard !activeTab.onStartPage, webView.url != nil else {
            showToast("Open a page first")
            return
        }
        // The script's own return value is undefined, which WebKit reports as an
        // error; a trailing literal keeps the completion honest about failures
        // that actually matter.
        webView.evaluateJavaScript(adBlockPickerScript + "\ntrue;") { [weak self] _, error in
            guard let error else { return }
            self?.showToast("Picker failed — \(error.localizedDescription)")
        }
    }

    @objc func showAdBlockSettings(_ sender: Any?) {
        AdBlockSettingsWindowController.shared.present()
    }

    @objc func newTabAction(_ sender: Any?) { addTab(url: nil) }

    @objc func closeTabAction(_ sender: Any?) { closeTab(at: activeIndex) }

    @objc func showNextTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeIndex + 1) % tabs.count)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeIndex - 1 + tabs.count) % tabs.count)
    }

    // Tag 1…8 jump to that tab; tag 9 jumps to the last one, as browsers do.
    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        selectTab(at: sender.tag == 9 ? tabs.count - 1 : sender.tag - 1)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackAction(_:)): return webView.canGoBack
        case #selector(goForwardAction(_:)): return webView.canGoForward
        case #selector(showNextTab(_:)), #selector(showPreviousTab(_:)):
            return tabs.count > 1
        case #selector(selectTabByNumber(_:)):
            return menuItem.tag == 9 ? tabs.count > 1 : menuItem.tag <= tabs.count
        case #selector(closeTabAction(_:)):
            menuItem.title = tabs.count > 1 ? "Close Tab" : "Close Window"
            return true
        case #selector(copyPageURL(_:)):
            return webView.url != nil && webView.url?.absoluteString != "about:blank"
        case #selector(togglePin(_:)):
            menuItem.state = window?.level == .floating ? .on : .off
            return true
        case #selector(toggleSiteBlocking(_:)):
            menuItem.state = adBlockManager.isBlocking(webView.url) ? .on : .off
            return adBlockManager.settings.enabled && AdBlockManager.domain(for: webView.url) != nil
        case #selector(pickElementToBlock(_:)):
            return !activeTab.onStartPage && webView.url != nil
        case #selector(toggleWebInspector(_:)):
            menuItem.title = isWebInspectorVisible ? "Hide Web Inspector" : "Show Web Inspector"
            return webInspector != nil
        default: return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidEnterFullScreen(_ notification: Notification) { setTrafficLights(visible: true) }
    func windowDidExitFullScreen(_ notification: Notification) { setTrafficLights(visible: false) }

    func windowWillClose(_ notification: Notification) {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        keyMonitor = nil
        downloadsHide?.cancel()
        downloadsHide = nil
        for observer in downloadsObservers { NotificationCenter.default.removeObserver(observer) }
        downloadsObservers.removeAll()
        if let observer = quickAccessObserver { NotificationCenter.default.removeObserver(observer) }
        quickAccessObserver = nil
        // Downloads outlive their window on purpose: the manager holds the
        // delegate, so tearing down these tabs does not stop a transfer.
        for tab in tabs { tab.teardown() }
        onClose?()
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let u = webView.url?.absoluteString
        if u != nil && u != "about:blank" { tab(for: webView)?.onStartPage = false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let finished = tab(for: webView) else { return }
        tabBar.update(titleAt: tabs.firstIndex { $0 === finished }, to: finished.displayTitle)
        guard finished === activeTab else { return }
        if let job = snapJob {
            snapJob = nil
            runSnapJob(job)
        } else if finished.onStartPage {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.activeTab.onStartPage,
                      self.window?.isKeyWindow == true else { return }
                self.showHUD()
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadError(error, in: webView)
    }

    private func handleLoadError(_ error: Error, in webView: WKWebView) {
        let e = error as NSError
        // Ignore cancelled loads and "frame load interrupted" (downloads, redirects).
        if e.code == NSURLErrorCancelled || e.code == 102 { return }
        if launchOptions.snap != nil {
            fputs("chromeless: load failed: \(e.localizedDescription)\n", stderr)
            exit(1)
        }
        // The toast reports on the page you are looking at, so a background
        // tab failing quietly keeps its error state until you switch to it.
        guard tab(for: webView) === activeTab else { return }
        showToast("Couldn’t load — \(e.localizedDescription)")
    }

    private func exitForSnapDownload() -> Never {
        fputs("chromeless: page attempted to download a file during --snap\n", stderr)
        exit(1)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Hand non-web schemes (mailto:, facetime:, app links…) to the system.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "file", "about", "data", "blob", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            if launchOptions.snap != nil { exitForSnapDownload() }
            pendingDownloadWantsPanel = navigationAction.modifierFlags.contains(.option)
            decisionHandler(.download)
            return
        }
        // Remember the modifier even for links that only turn out to be
        // downloads once the response headers arrive.
        pendingDownloadWantsPanel = navigationAction.modifierFlags.contains(.option)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = ((navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        if !navigationResponse.canShowMIMEType || disposition.contains("attachment") {
            if launchOptions.snap != nil { exitForSnapDownload() }
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        beginDownload(download, from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        beginDownload(download, from: webView)
    }

    private func beginDownload(_ download: WKDownload, from webView: WKWebView) {
        if launchOptions.snap != nil { exitForSnapDownload() }
        let wantsPanel = pendingDownloadWantsPanel
        pendingDownloadWantsPanel = false
        downloadManager.attach(download, from: webView, wantsSavePanel: wantsPanel)
        if !wantsPanel { showDownloadsPanel(pinned: false) }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // --snap is a one-shot screenshot: never fan out into tabs.
        if launchOptions.snap != nil {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }
        // Background opening is not decided here. A middle-click never reaches
        // this method — the page script cancels it and reports the href instead
        // — and ⌘-click never reaches the page at all, because `BrowserWebView`
        // claims ⌘ for dragging the window.
        // Handing back a live web view lets WebKit drive the load itself, so
        // window.open + document.write popups work, not just plain links.
        return addTab(url: nil, configuration: configuration).webView
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // WebKit owns no file chooser of its own: without this method a click on
    // <input type="file"> does nothing at all — no panel, no error, no console
    // message. The completion handler must run exactly once, or the input stays
    // wedged for the rest of the page's life and never asks again.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        var answered = false
        let reply: ([URL]?) -> Void = { urls in
            guard !answered else { return }
            answered = true
            completionHandler(urls)
        }

        // --snap is a one-shot screenshot; stopping for a panel would hang it.
        guard launchOptions.snap == nil else {
            reply(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        // `webkitdirectory` asks for a folder, and WebKit walks it itself. The
        // two modes are exclusive: offering both lets the page get a kind of
        // path it never asked for.
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = parameters.allowsDirectories ? "Choose Folder" : "Choose"
        // No type filter: `accept` is not exposed on WKOpenPanelParameters, and
        // guessing it from the page would only make valid files unselectable.
        if let host = frame.request.url?.host ?? webView.url?.host {
            panel.message = "Choose \(parameters.allowsDirectories ? "a folder" : "files") to upload to \(host)"
        }

        // The ⌘L HUD floats inside the window and would sit under the sheet.
        hideHUD()

        let finish: (NSApplication.ModalResponse) -> Void = { result in
            reply(result == .OK && !panel.urls.isEmpty ? panel.urls : nil)
        }
        if let window = webView.window ?? self.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var controllers: [BrowserWindowController] = []
    private var profilePickerProfiles: [BrowserProfile] = []
    private var profilePickerSelectedID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        // Compiling takes a moment, and the first page can load before the list
        // is ready. Reloading it out from under the user to catch a handful of
        // early requests would be worse than missing them.
        adBlockManager.rebuild()
        if launchOptions.snap == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                adBlockManager.updateAll(force: false)
            }
            // A shortcut saved while the machine was offline still has no icon.
            quickAccessStore.refreshMissingIcons()
        }

        guard let profile = profileStore.profile(matching: launchOptions.profile) else {
            fputs("chromeless: profile not found: \(launchOptions.profile ?? "")\n", stderr)
            exit(1)
        }
        let url: URL? = {
            if let u = launchOptions.url { return u }
            if launchOptions.snap != nil { return nil }
            if launchOptions.restoreLastPage,
               let s = profile.lastURL { return URL(string: s) }
            return nil
        }()
        // A URL opened from another app (`open -a Chromeless <url>`, a link
        // clicked somewhere else) arrives through application(_:open:), which
        // AppKit calls *before* this method, so a window is already up. Opening
        // the start page as well used to bury it: the link looked like it had
        // been swallowed, when it was loading one window behind.
        if url == nil && launchOptions.snap == nil && !controllers.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        openWindow(profile: profile, url: url, size: launchOptions.size, snap: launchOptions.snap, isPrimary: true)
        NSApp.activate(ignoringOtherApps: true)

        if launchOptions.snap != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                fputs("chromeless: --snap timed out\n", stderr)
                exit(2)
            }
        }
    }

    func openWindow(profile: BrowserProfile, url: URL?, size: NSSize? = nil,
                    snap: SnapJob? = nil, isPrimary: Bool = false) {
        let controller = BrowserWindowController(
            profile: profile, url: url, size: size, snap: snap, isPrimary: isPrimary)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc func newWindow(_ sender: Any?) { presentProfilePicker(from: nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Closing the last window quits the app, so without this a download that is
    // 90% done dies silently when you close the window it started from.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard downloadManager.hasActiveDownloads, launchOptions.snap == nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A download is still in progress."
        alert.informativeText = "Quitting now cancels it."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            downloadManager.cancelAll()
            return .terminateNow
        }
        return .terminateCancel
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openWindow(profile: profileStore.defaultProfile, url: url) }
    }

    func presentProfilePicker(from controller: BrowserWindowController?) {
        profilePickerProfiles = profileStore.profiles
        let preferredID = controller?.profileID
            ?? NSApp.keyWindow
                .flatMap { window in controllers.first { $0.window === window }?.profileID }
            ?? profileStore.defaultProfile.id
        profilePickerSelectedID = profilePickerProfiles.first { $0.id == preferredID }?.id
            ?? profilePickerProfiles.first?.id

        let alert = NSAlert()
        alert.messageText = "Choose Profile"
        alert.informativeText = "Open the new window with separate cookies, cache, and session data."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "New Profile...")
        alert.addButton(withTitle: "Delete Profile")
        alert.addButton(withTitle: "Cancel")

        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 430, height: 1))
        table.headerView = nil
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Profile"))
        column.width = 430
        table.addTableColumn(column)

        let scrollHeight = min(280, max(64, profilePickerProfiles.count * 58))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: scrollHeight))
        scroll.hasVerticalScroller = profilePickerProfiles.count > 5
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        alert.accessoryView = scroll

        table.reloadData()
        if let id = profilePickerSelectedID,
           let row = profilePickerProfiles.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let profile = selectedPickerProfile() {
                openWindow(profile: profile, url: nil)
            }
        case .alertSecondButtonReturn:
            if let profile = selectedPickerProfile() {
                profileStore.setDefaultProfile(profile)
                presentProfilePicker(from: nil)
            }
        case .alertThirdButtonReturn:
            createProfileThenOpenWindow()
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            if let profile = selectedPickerProfile() {
                confirmDeleteProfile(profile)
            } else {
                presentProfilePicker(from: nil)
            }
        default:
            break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        profilePickerProfiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profilePickerProfiles.indices.contains(row) else { return nil }
        let profile = profilePickerProfiles[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 430, height: 54))

        let isDefault = profile.id == profileStore.defaultProfile.id
        let title = NSTextField(labelWithString: isDefault ? "\(profile.name) (Default)" : profile.name)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 12, y: 28, width: 390, height: 18)
        title.autoresizingMask = [.width]

        let detailText = profile.lastURL ?? (isDefault ? "Default profile" : "No saved page yet")
        let detail = NSTextField(labelWithString: detailText)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.frame = NSRect(x: 12, y: 9, width: 390, height: 15)
        detail.autoresizingMask = [.width]

        cell.addSubview(title)
        cell.addSubview(detail)
        cell.textField = title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if profilePickerProfiles.indices.contains(table.selectedRow) {
            profilePickerSelectedID = profilePickerProfiles[table.selectedRow].id
        }
    }

    private func selectedPickerProfile() -> BrowserProfile? {
        guard let id = profilePickerSelectedID else { return profilePickerProfiles.first }
        return profilePickerProfiles.first { $0.id == id } ?? profilePickerProfiles.first
    }

    private func createProfileThenOpenWindow() {
        let alert = NSAlert()
        alert.messageText = "New Profile"
        alert.informativeText = "Create a separate browser identity for another account."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Work, Personal, Client..."
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let profile = try profileStore.createProfile(named: field.stringValue)
            openWindow(profile: profile, url: nil)
        } catch {
            let errorAlert = NSAlert(error: error)
            errorAlert.messageText = "Couldn’t Create Profile"
            errorAlert.runModal()
        }
    }

    private func confirmDeleteProfile(_ profile: BrowserProfile) {
        if controllers.contains(where: { $0.profileID == profile.id }) {
            let alert = NSAlert()
            alert.messageText = "Close Profile Windows First"
            alert.informativeText = "Close all windows using “\(profile.name)” before deleting that profile."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            presentProfilePicker(from: nil)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(profile.name)”?"
        alert.informativeText = "This removes the profile metadata and its website data, including cookies, cache, local storage, history, and login sessions."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            presentProfilePicker(from: nil)
            return
        }

        profileStore.deleteProfile(profile) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    let errorAlert = NSAlert(error: error)
                    errorAlert.messageText = "Couldn’t Delete Profile"
                    errorAlert.runModal()
                }
                self?.presentProfilePicker(from: nil)
            }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Chromeless",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Chromeless", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Chromeless", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Chromeless", action: nil, keyEquivalent: "").submenu = appMenu

        let fileMenu = NSMenu(title: "File")
        let newWin = fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        newWin.target = self
        fileMenu.addItem(withTitle: "New Tab",
                         action: #selector(BrowserWindowController.newTabAction(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open Location…",
                         action: #selector(BrowserWindowController.openLocation(_:)), keyEquivalent: "l")
        fileMenu.addItem(.separator())
        let snap = fileMenu.addItem(withTitle: "Save Snapshot to Desktop",
                                    action: #selector(BrowserWindowController.saveSnapshot(_:)), keyEquivalent: "s")
        snap.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        // ⌘W closes the tab, and closes the window when it is the last one, so
        // the old muscle memory still lands where it used to.
        fileMenu.addItem(withTitle: "Close Tab",
                         action: #selector(BrowserWindowController.closeTabAction(_:)), keyEquivalent: "w")
        let closeWin = fileMenu.addItem(withTitle: "Close Window",
                                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWin.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = fileMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let copyURL = editMenu.addItem(withTitle: "Copy Current URL",
                                       action: #selector(BrowserWindowController.copyPageURL(_:)), keyEquivalent: "c")
        copyURL.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload Page",
                         action: #selector(BrowserWindowController.reloadPage(_:)), keyEquivalent: "r")
        let hardReload = viewMenu.addItem(withTitle: "Reload Ignoring Cache",
                                          action: #selector(BrowserWindowController.hardReloadPage(_:)), keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In",
                         action: #selector(BrowserWindowController.zoomInPage(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out",
                         action: #selector(BrowserWindowController.zoomOutPage(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size",
                         action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let home = viewMenu.addItem(withTitle: "Home",
                                    action: #selector(BrowserWindowController.goHome(_:)), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        let downloads = viewMenu.addItem(
            withTitle: "Show Downloads",
            action: #selector(BrowserWindowController.toggleDownloadsPanel(_:)), keyEquivalent: "j")
        downloads.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        let siteBlocking = viewMenu.addItem(
            withTitle: "Block Ads on This Site",
            action: #selector(BrowserWindowController.toggleSiteBlocking(_:)), keyEquivalent: "b")
        siteBlocking.keyEquivalentModifierMask = [.command, .shift]
        let picker = viewMenu.addItem(
            withTitle: "Pick Element to Hide…",
            action: #selector(BrowserWindowController.pickElementToBlock(_:)), keyEquivalent: "e")
        picker.keyEquivalentModifierMask = [.command, .shift, .control]
        viewMenu.addItem(withTitle: "Ad Blocking…",
                         action: #selector(BrowserWindowController.showAdBlockSettings(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        let inspector = viewMenu.addItem(
            withTitle: "Show Web Inspector",
            action: #selector(BrowserWindowController.toggleWebInspector(_:)), keyEquivalent: "i")
        inspector.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = viewMenu

        let historyMenu = NSMenu(title: "History")
        historyMenu.addItem(withTitle: "Back",
                            action: #selector(BrowserWindowController.goBackAction(_:)), keyEquivalent: "[")
        historyMenu.addItem(withTitle: "Forward",
                            action: #selector(BrowserWindowController.goForwardAction(_:)), keyEquivalent: "]")
        main.addItem(withTitle: "History", action: nil, keyEquivalent: "").submenu = historyMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let nextTab = windowMenu.addItem(withTitle: "Show Next Tab",
                                         action: #selector(BrowserWindowController.showNextTab(_:)),
                                         keyEquivalent: "]")
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        let prevTab = windowMenu.addItem(withTitle: "Show Previous Tab",
                                         action: #selector(BrowserWindowController.showPreviousTab(_:)),
                                         keyEquivalent: "[")
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        for n in 1...9 {
            let item = windowMenu.addItem(
                withTitle: n == 9 ? "Show Last Tab" : "Show Tab \(n)",
                action: #selector(BrowserWindowController.selectTabByNumber(_:)),
                keyEquivalent: "\(n)")
            item.tag = n
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Pin on Top",
                           action: #selector(BrowserWindowController.togglePin(_:)), keyEquivalent: "p")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Chromeless Help",
                         action: #selector(BrowserWindowController.showHelpPage(_:)), keyEquivalent: "?")
        main.addItem(withTitle: "Help", action: nil, keyEquivalent: "").submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }
}

// MARK: - Boot

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
