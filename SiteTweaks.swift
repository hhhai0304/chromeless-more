import Cocoa

// Heavyweight interactive apps — remote desktops, live terminals — benefit
// from treatment a normal page should not get. Entries come from two places:
// the built-in `siteTweaks` table below, and `site-tweaks.json` in
// ~/Library/Application Support/Chromeless/, which the user edits through
// the Settings window (or by hand) and which beats the built-in table on a
// matching key. Anything here is granted by host only, so a random site
// never earns the same freedom.
struct SiteTweaks {
    /// Hold off App Nap, idle sleep, and display sleep while the site is the
    /// active tab of a visible window — a remote session must not freeze
    /// because the local screen went dark.
    var keepAwake = false
    /// Present a Chrome user agent — the global default, since Google apps
    /// serve Chrome a faster path (Sheets' Safari branch renders its grid
    /// canvas at half resolution). Set false to keep the real Safari UA for
    /// a site that misbehaves under the spoof.
    var chromeUserAgent = true
    /// Keep the page fully alive in the background: no window-occlusion
    /// suspension (video keeps painting under a covered or minimized window)
    /// and no DOM timer throttling in a non-front tab. Costs idle CPU/GPU —
    /// that is the trade, and it is why it is per site.
    var backgroundWork = false
    /// Treat the page as a native app, not a document — a live terminal or
    /// remote desktop where every piece of browser chrome is in the way:
    /// ⌃Tab and F12 go to the page, the right-click menu belongs to the page
    /// alone, back/forward gestures are off, and closing, reloading, going
    /// home, or quitting the window asks first — all of them end a session
    /// the moment the page unloads.
    var appMode = false
}

extension SiteTweaks: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
        chromeUserAgent = try c.decodeIfPresent(Bool.self, forKey: .chromeUserAgent) ?? true
        backgroundWork = try c.decodeIfPresent(Bool.self, forKey: .backgroundWork) ?? false
        appMode = try c.decodeIfPresent(Bool.self, forKey: .appMode) ?? false
    }
}

// Defaults for sites any user benefits from. Personal hosts go in the JSON
// file — they need no rebuild.
let siteTweaks: [String: SiteTweaks] = [
    "remotedesktop.google.com": SiteTweaks(
        keepAwake: true, chromeUserAgent: true, backgroundWork: true, appMode: true),
]

let siteTweaksFileURL: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Chromeless/site-tweaks.json")
}()

// Keys are host patterns: an exact hostname, or one `*` standing for any
// run of characters (`ssh*.example.com` covers ssh-a.example.com and
// ssh.example.com). Exact keys beat patterns; the user file beats the
// built-in table. Keys no page can ever have as a host (`_readme`, notes)
// simply match nothing.
func tweaksForHost(_ host: String?) -> SiteTweaks? {
    guard let host, !host.isEmpty else { return nil }
    let h = host.lowercased()
    return matchSiteTweaks(in: userSiteTweaks(), host: h)
        ?? matchSiteTweaks(in: siteTweaks, host: h)
}

private func matchSiteTweaks(in table: [String: SiteTweaks], host: String) -> SiteTweaks? {
    if let t = table[host] { return t }
    for (pattern, tweaks) in table where pattern.contains("*") {
        let parts = pattern.lowercased().split(separator: "*", omittingEmptySubsequences: false)
        guard parts.count == 2,
              host.count >= parts[0].count + parts[1].count,
              host.hasPrefix(String(parts[0])),
              host.hasSuffix(String(parts[1])) else { continue }
        return tweaks
    }
    return nil
}

func isSessionHost(_ url: URL?) -> Bool {
    tweaksForHost(url?.host)?.appMode == true
}

// The file is re-read only when its mtime moves, so a lookup per keystroke
// costs one stat and nothing more.
private var siteTweaksFileMtime: Date?
private var siteTweaksFileCache: [String: SiteTweaks] = [:]

func userSiteTweaks() -> [String: SiteTweaks] {
    let url = siteTweaksFileURL
    let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    if mtime == siteTweaksFileMtime { return siteTweaksFileCache }
    defer { siteTweaksFileMtime = mtime }
    guard let data = try? Data(contentsOf: url),
          let table = try? JSONDecoder().decode([String: SiteTweaks].self, from: data)
    else {
        siteTweaksFileCache = [:]
        return [:]
    }
    siteTweaksFileCache = table
    return table
}

private let siteTweaksReadme =
    "Host pattern -> tweaks for every page on matching hosts. One '*' in a key matches any " +
    "characters: ssh*.example.com covers ssh-a.example.com and ssh.example.com. An exact host " +
    "beats a pattern; an entry here beats the built-in table. Flags: keepAwake (no App Nap or " +
    "sleep while the site is visible), backgroundWork (no suspension or timer throttling while " +
    "hidden), chromeUserAgent (on by default; false keeps the real Safari UA), appMode (the page owns the keyboard and the right-click; close, " +
    "reload and quit ask first — for live terminals and remote desktops)."

// The `_readme` key decodes to an all-false entry under a name no host can
// match — docs that ride inside the file without affecting a single site.
// Every write puts it back, so hand edits that drop it only lose the docs.
func saveUserSiteTweaks(_ table: [String: SiteTweaks]) {
    var obj: [String: Any] = ["_readme": ["note": siteTweaksReadme]]
    for (key, t) in table where !key.hasPrefix("_") {
        obj[key] = [
            "keepAwake": t.keepAwake, "chromeUserAgent": t.chromeUserAgent,
            "backgroundWork": t.backgroundWork, "appMode": t.appMode,
        ]
    }
    guard let data = try? JSONSerialization.data(
        withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
    do {
        try FileManager.default.createDirectory(
            at: siteTweaksFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: siteTweaksFileURL, options: .atomic)
        siteTweaksFileMtime = nil
    } catch {
        fputs("chromeless: could not save site tweaks: \(error.localizedDescription)\n", stderr)
    }
}

// Per-site page zoom lives in UserDefaults under this key — written by the
// window controller's site-zoom map, listed and cleared in the Settings
// window.
let siteZoomDefaultsKey = "ChromelessSiteZooms"

// First launch plants a documented template so the file exists where the
// Settings window and the README point — a user who never needs it never
// thinks about it again.
func seedSiteTweaksFile() {
    let url = siteTweaksFileURL
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    saveUserSiteTweaks([
        "ssh*.example.com": SiteTweaks(
            keepAwake: true, backgroundWork: true, appMode: true),
    ])
}
