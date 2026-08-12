// AdBlock.swift — settings, compilation, and the live rule list.
//
// The blocker is WebKit's own content-blocker engine: filter text becomes a
// `WKContentRuleList`, and the list is handed to every web view. Nothing here
// inspects or intercepts a request; WebKit does the matching in its networking
// process, which is why it costs nothing at page load.
//
// Compiled lists are cached by the SHA-256 of their JSON, so a rule set that has
// been built before — including flipping a site's allowlist entry back and forth
// — comes straight out of `WKContentRuleListStore` with no compile at all.

import Cocoa
import CryptoKit
import WebKit

extension Notification.Name {
    static let adBlockDidChange = Notification.Name("chromeless.adBlockDidChange")
}

// MARK: - Model

struct AdBlockSubscription: Codable, Equatable {
    var id: String
    var name: String
    var url: String
    var enabled: Bool
    var updatedAt: Date?
    var etag: String?
    var ruleCount: Int
    var lastError: String?

    var isBuiltInDefault: Bool {
        AdBlockSettings.defaultSubscriptions.contains { $0.id == id }
    }
}

// What the last successful build produced. Converting 135k filter lines takes a
// couple of seconds, and it happens before the identifier — and therefore the
// compiled-list cache — is even known. Remembering the identifier next to a
// fingerprint of the inputs turns an unchanged launch into a single lookup.
struct CompiledSnapshot: Codable {
    var identifier: String
    var fingerprint: String
    var ruleCount: Int
    var droppedCount: Int
    var skippedCount: Int
}

struct AdBlockSettings: Codable {
    var enabled = true
    // Registrable domains the user switched blocking off for.
    var allowlist: [String] = []
    var customRules = ""
    var subscriptions: [AdBlockSubscription] = AdBlockSettings.defaultSubscriptions
    var compiled: CompiledSnapshot?

    // EasyList and EasyPrivacy are the two lists almost every blocker starts
    // from; ABPVN covers the Vietnamese ad networks the built-in list only
    // samples. All three are enabled on first launch and fetched in the
    // background — the built-in list is already blocking while they arrive.
    static let defaultSubscriptions: [AdBlockSubscription] = [
        AdBlockSubscription(
            id: "easylist", name: "EasyList",
            url: "https://easylist.to/easylist/easylist.txt",
            enabled: true, updatedAt: nil, etag: nil, ruleCount: 0, lastError: nil),
        AdBlockSubscription(
            id: "easyprivacy", name: "EasyPrivacy",
            url: "https://easylist.to/easylist/easyprivacy.txt",
            enabled: true, updatedAt: nil, etag: nil, ruleCount: 0, lastError: nil),
        AdBlockSubscription(
            id: "abpvn", name: "ABPVN (Vietnamese)",
            url: "https://raw.githubusercontent.com/abpvn/abpvn/master/filter/abpvn.txt",
            enabled: true, updatedAt: nil, etag: nil, ruleCount: 0, lastError: nil),
    ]
}

// MARK: - Manager

final class AdBlockManager {
    static let shared = AdBlockManager()

    private(set) var settings: AdBlockSettings
    private(set) var ruleList: WKContentRuleList?
    private(set) var activeRuleCount = 0
    private(set) var droppedRuleCount = 0
    private(set) var skippedLineCount = 0
    private(set) var isBuilding = false
    private(set) var isUpdating = false
    private(set) var buildError: String?

    private let directoryURL: URL
    private let settingsURL: URL
    private let listsURL: URL
    // Weak, so a closed window's web views are not kept alive by the blocker.
    private let webViews = NSHashTable<WKWebView>.weakObjects()
    private let buildQueue = DispatchQueue(label: "chromeless.adblock.build", qos: .utility)
    private var currentIdentifier: String?
    // A rebuild requested while one is running is coalesced into a single
    // follow-up, so holding ⇧⌘B down cannot queue twenty compiles. Their
    // completions ride along to the build that actually lands.
    private var rebuildQueued = false
    private var pendingCompletions: [(Bool) -> Void] = []

    private static let maxListBytes = 20 * 1024 * 1024
    private static let updateInterval: TimeInterval = 7 * 24 * 60 * 60

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directoryURL = appSupport.appendingPathComponent("Chromeless/AdBlock", isDirectory: true)
        settingsURL = directoryURL.appendingPathComponent("adblock.json")
        listsURL = directoryURL.appendingPathComponent("lists", isDirectory: true)
        settings = AdBlockSettings()
        loadSettings()
    }

    // MARK: Web views

    func register(_ webView: WKWebView) {
        webViews.add(webView)
        attach(to: webView)
    }

    private func attach(to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if settings.enabled, let list = ruleList { controller.add(list) }
    }

    private func attachToAll() {
        for webView in webViews.allObjects { attach(to: webView) }
    }

    // MARK: Allowlist

    func isAllowlisted(_ url: URL?) -> Bool {
        guard let domain = Self.domain(for: url) else { return false }
        return settings.allowlist.contains(domain)
    }

    // Whether the blocker is doing anything on this page at all.
    func isBlocking(_ url: URL?) -> Bool {
        settings.enabled && !isAllowlisted(url)
    }

    static func domain(for url: URL?) -> String? {
        guard let host = url?.host, !host.isEmpty else { return nil }
        return registrableDomain(for: host)
    }

    @discardableResult
    func setBlocking(_ blocking: Bool, for url: URL?, completion: (() -> Void)? = nil) -> Bool {
        guard let domain = Self.domain(for: url) else { return false }
        if blocking {
            settings.allowlist.removeAll { $0 == domain }
        } else if !settings.allowlist.contains(domain) {
            settings.allowlist.append(domain)
        }
        saveSettings()
        rebuild { _ in completion?() }
        return true
    }

    func removeFromAllowlist(_ domain: String) {
        settings.allowlist.removeAll { $0 == domain }
        saveSettings()
        rebuild()
    }

    func setEnabled(_ enabled: Bool, completion: (() -> Void)? = nil) {
        settings.enabled = enabled
        saveSettings()
        rebuild { _ in completion?() }
    }

    // MARK: Custom rules

    func setCustomRules(_ text: String, completion: (() -> Void)? = nil) {
        settings.customRules = text
        saveSettings()
        rebuild { _ in completion?() }
    }

    func appendCustomRule(_ line: String, completion: (() -> Void)? = nil) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion?(); return }
        var lines = settings.customRules.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.contains(trimmed) else { completion?(); return }
        lines.append(trimmed)
        setCustomRules(lines.joined(separator: "\n"), completion: completion)
    }

    // MARK: Subscriptions

    func setSubscription(id: String, enabled: Bool) {
        guard let index = settings.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        settings.subscriptions[index].enabled = enabled
        saveSettings()
        if enabled && !FileManager.default.fileExists(atPath: listFileURL(for: id).path) {
            update(subscriptionID: id, force: true) { [weak self] in self?.rebuild() }
        } else {
            rebuild()
        }
    }

    func removeSubscription(id: String) {
        settings.subscriptions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: listFileURL(for: id))
        saveSettings()
        rebuild()
    }

    func addSubscription(name rawName: String, url rawURL: String, completion: @escaping (String?) -> Void) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            completion("That does not look like a filter-list URL.")
            return
        }
        if settings.subscriptions.contains(where: { $0.url == trimmed }) {
            completion("That list is already subscribed.")
            return
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subscription = AdBlockSubscription(
            id: Self.hash(trimmed).prefix(12).description,
            name: name.isEmpty ? (url.host ?? "Filter list") : name,
            url: trimmed, enabled: true, updatedAt: nil, etag: nil, ruleCount: 0, lastError: nil)
        settings.subscriptions.append(subscription)
        saveSettings()
        notifyChanged()
        update(subscriptionID: subscription.id, force: true) { [weak self] in
            guard let self else { return }
            let stored = self.settings.subscriptions.first { $0.id == subscription.id }
            self.rebuild { _ in completion(stored?.lastError) }
        }
    }

    // MARK: Updating

    // Anything older than a week, or everything when the user asks for it.
    func updateAll(force: Bool, completion: (() -> Void)? = nil) {
        let due = settings.subscriptions.filter { subscription in
            guard subscription.enabled else { return false }
            if force { return true }
            guard let updatedAt = subscription.updatedAt else { return true }
            if !FileManager.default.fileExists(atPath: listFileURL(for: subscription.id).path) { return true }
            return Date().timeIntervalSince(updatedAt) > Self.updateInterval
        }
        guard !due.isEmpty else { completion?(); return }

        isUpdating = true
        notifyChanged()
        let group = DispatchGroup()
        for subscription in due {
            group.enter()
            update(subscriptionID: subscription.id, force: force) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.isUpdating = false
            self.rebuild { _ in completion?() }
        }
    }

    private func update(subscriptionID: String, force: Bool, completion: @escaping () -> Void) {
        guard let index = settings.subscriptions.firstIndex(where: { $0.id == subscriptionID }) else {
            completion()
            return
        }
        let subscription = settings.subscriptions[index]
        guard let url = URL(string: subscription.url) else {
            finishUpdate(id: subscriptionID, error: "Invalid URL", completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        // A 304 costs one round trip instead of two megabytes.
        if let etag = subscription.etag, !force { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.setValue("chromeless", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { completion(); return }
                if let error {
                    self.finishUpdate(id: subscriptionID, error: error.localizedDescription, completion: completion)
                    return
                }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if status == 304 {
                    self.finishUpdate(id: subscriptionID, error: nil, completion: completion)
                    return
                }
                guard status == 200, let data, !data.isEmpty else {
                    self.finishUpdate(id: subscriptionID, error: "HTTP \(status)", completion: completion)
                    return
                }
                guard data.count <= Self.maxListBytes else {
                    self.finishUpdate(id: subscriptionID, error: "List is too large", completion: completion)
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    self.finishUpdate(id: subscriptionID, error: "List is not UTF-8", completion: completion)
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: self.listsURL, withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: self.listFileURL(for: subscriptionID), options: .atomic)
                } catch {
                    self.finishUpdate(id: subscriptionID, error: error.localizedDescription, completion: completion)
                    return
                }
                if let i = self.settings.subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
                    self.settings.subscriptions[i].etag = http?.value(forHTTPHeaderField: "ETag")
                }
                self.finishUpdate(id: subscriptionID, error: nil, completion: completion)
            }
        }.resume()
    }

    private func finishUpdate(id: String, error: String?, completion: @escaping () -> Void) {
        if let index = settings.subscriptions.firstIndex(where: { $0.id == id }) {
            settings.subscriptions[index].lastError = error
            if error == nil { settings.subscriptions[index].updatedAt = Date() }
        }
        saveSettings()
        notifyChanged()
        completion()
    }

    // MARK: Building

    func rebuild(completion: ((Bool) -> Void)? = nil) {
        // Callers reload their tab when this fires, so it has to wait for the
        // list that reflects their change — not for whichever build happened to
        // be in flight when they asked.
        if let completion { pendingCompletions.append(completion) }
        guard !isBuilding else {
            rebuildQueued = true
            return
        }
        isBuilding = true
        buildError = nil
        notifyChanged()
        startBuild()
    }

    private func startBuild() {
        // Nothing about the inputs changed since the last build, so the list
        // WebKit already has compiled is the right one — no conversion, no
        // compile, just a lookup. This is what keeps a launch from browsing
        // unprotected for the first few seconds.
        let fingerprint = inputFingerprint()
        if settings.enabled, let compiled = settings.compiled, compiled.fingerprint == fingerprint,
           let store = WKContentRuleListStore.default() {
            store.lookUpContentRuleList(forIdentifier: compiled.identifier) { [weak self] list, _ in
                guard let self else { return }
                guard let list else {
                    // WebKit dropped the compiled list; build it again.
                    self.buildFromSources()
                    return
                }
                self.finishBuild(list, ruleCount: compiled.ruleCount, dropped: compiled.droppedCount,
                                 skipped: compiled.skippedCount, identifier: compiled.identifier,
                                 fingerprint: fingerprint, error: nil)
            }
            return
        }
        buildFromSources()
    }

    // A cheap stand-in for the converted output: the converter's version, the
    // rules the user owns, and the size and timestamp of every list file. Any
    // real change moves at least one of them.
    private func inputFingerprint() -> String {
        var parts = ["v\(FilterCompiler.version)",
                     settings.allowlist.sorted().joined(separator: ","),
                     Self.hash(settings.customRules)]
        for subscription in settings.subscriptions where subscription.enabled {
            let path = listFileURL(for: subscription.id).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? Int) ?? -1
            let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            parts.append("\(subscription.id):\(size):\(Int(stamp))")
        }
        return Self.hash(parts.joined(separator: "|"))
    }

    private func buildFromSources() {
        let fingerprint = inputFingerprint()
        let snapshot = settings
        let sources: [URL] = snapshot.subscriptions
            .filter(\.enabled)
            .map { listFileURL(for: $0.id) }
        let subscriptionIDs = snapshot.subscriptions.filter(\.enabled).map(\.id)

        buildQueue.async { [weak self] in
            guard let self else { return }
            // Priority order, which is also the order the cap trims from the
            // back of: the built-in list and the user's own rules can never be
            // pushed out by a subscription.
            var compiler = FilterCompiler()
            compiler.ingest(builtInFilterList)
            compiler.ingest(snapshot.customRules)
            var perList: [String: Int] = [:]
            for (id, url) in zip(subscriptionIDs, sources) {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let before = compiler.ruleCountSoFar
                compiler.ingest(text)
                perList[id] = compiler.ruleCountSoFar - before
            }
            let set = compiler.finish(allowlist: snapshot.allowlist)
            let identifier = "chromeless-" + Self.hash(set.json).prefix(32).description

            DispatchQueue.main.async {
                for (id, count) in perList {
                    if let i = self.settings.subscriptions.firstIndex(where: { $0.id == id }) {
                        self.settings.subscriptions[i].ruleCount = count
                    }
                }
                self.install(set, identifier: identifier, fingerprint: fingerprint, allowFallback: true)
            }
        }
    }

    private func install(_ set: CompiledRuleSet, identifier: String,
                         fingerprint: String?, allowFallback: Bool) {
        func done(_ list: WKContentRuleList?, _ id: String?, _ error: String?) {
            finishBuild(list, ruleCount: set.ruleCount, dropped: set.droppedCount,
                        skipped: set.skippedCount, identifier: id,
                        fingerprint: id == nil ? nil : fingerprint, error: error)
        }
        guard let store = WKContentRuleListStore.default() else {
            done(nil, nil, "WebKit has no rule-list store.")
            return
        }
        // Blocking off means no list at all, rather than an empty one.
        guard settings.enabled else {
            done(nil, nil, nil)
            return
        }

        store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] cached, _ in
            guard let self else { return }
            if let cached {
                done(cached, identifier, nil)
                return
            }
            store.compileContentRuleList(forIdentifier: identifier,
                                         encodedContentRuleList: set.json) { compiled, error in
                if let compiled {
                    done(compiled, identifier, nil)
                    return
                }
                let message = error?.localizedDescription ?? "Compilation failed"
                guard allowFallback else {
                    done(nil, nil, message)
                    return
                }
                // One bad line in a subscription would otherwise take the whole
                // blocker down. Fall back to what ships in the binary, and say
                // so rather than looking like everything is fine.
                self.installFallback(reason: message)
            }
        }
    }

    private func installFallback(reason: String) {
        var compiler = FilterCompiler()
        compiler.ingest(builtInFilterList)
        compiler.ingest(settings.customRules)
        let set = compiler.finish(allowlist: settings.allowlist)
        let identifier = "chromeless-fallback-" + Self.hash(set.json).prefix(16).description
        buildError = "Subscriptions could not be compiled (\(reason)). Using built-in rules only."
        // No fingerprint: this list is not what the inputs describe, so the next
        // launch must try the real thing again rather than reuse the fallback.
        install(set, identifier: identifier, fingerprint: nil, allowFallback: false)
    }

    private func finishBuild(_ list: WKContentRuleList?, ruleCount: Int, dropped: Int, skipped: Int,
                             identifier: String?, fingerprint: String?, error: String?) {
        ruleList = list
        currentIdentifier = identifier
        activeRuleCount = list == nil ? 0 : ruleCount
        droppedRuleCount = dropped
        skippedLineCount = skipped
        if let error { buildError = error }
        // Only a list that actually compiled is worth remembering.
        if list != nil, let identifier, let fingerprint {
            settings.compiled = CompiledSnapshot(
                identifier: identifier, fingerprint: fingerprint,
                ruleCount: ruleCount, droppedCount: dropped, skippedCount: skipped)
        }
        isBuilding = false
        attachToAll()
        saveSettings()
        notifyChanged()
        pruneStaleLists()

        // A change arrived while this build was running, so what just landed is
        // already stale — the waiting callers want the next one, not this one.
        if rebuildQueued {
            rebuildQueued = false
            rebuild()
            return
        }
        let waiting = pendingCompletions
        pendingCompletions = []
        let ok = list != nil || !settings.enabled
        for run in waiting { run(ok) }
    }

    // Every distinct rule set leaves a compiled list behind in WebKit's store.
    // Keeping them would be a slow disk leak; keeping the current one is what
    // makes toggling a site back and forth instant.
    private func pruneStaleLists() {
        guard let store = WKContentRuleListStore.default(), let keep = currentIdentifier else { return }
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for identifier in identifiers ?? []
            where identifier.hasPrefix("chromeless-") && identifier != keep {
                store.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
        }
    }

    // MARK: Status

    var statusLine: String {
        if !settings.enabled { return "Ad blocking is off." }
        if isBuilding { return "Compiling rules…" }
        if let buildError { return buildError }
        var parts = ["\(activeRuleCount.formatted()) rules active"]
        if droppedRuleCount > 0 { parts.append("\(droppedRuleCount.formatted()) dropped over the cap") }
        if !settings.allowlist.isEmpty { parts.append("\(settings.allowlist.count) site(s) allowed") }
        if let newest = settings.subscriptions.compactMap(\.updatedAt).max() {
            parts.append("updated \(Self.relative(newest))")
        }
        return parts.joined(separator: " · ")
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .adBlockDidChange, object: nil)
    }

    // MARK: Storage

    private func listFileURL(for id: String) -> URL {
        listsURL.appendingPathComponent("\(id).txt")
    }

    private func loadSettings() {
        do {
            try FileManager.default.createDirectory(at: listsURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: settingsURL.path) else { return }
            let data = try Data(contentsOf: settingsURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            settings = try decoder.decode(AdBlockSettings.self, from: data)
        } catch {
            fputs("chromeless: could not load ad-block settings: \(error.localizedDescription)\n", stderr)
        }
    }

    private func saveSettings() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        } catch {
            fputs("chromeless: could not save ad-block settings: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

let adBlockManager = AdBlockManager.shared

// MARK: - Compile test

// `--adblock-compiletest` — converts the built-in list plus every subscription
// already on disk and pushes the result through WebKit's real compiler. The
// converter's unit checks cannot catch a rule WebKit rejects, and one rejected
// rule fails the entire list, so this is the check that matters before shipping
// a change to the converter.
func runAdBlockCompileTest() -> Never {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let listsURL = appSupport.appendingPathComponent("Chromeless/AdBlock/lists", isDirectory: true)
    let files = ((try? FileManager.default.contentsOfDirectory(at: listsURL, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "txt" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var compiler = FilterCompiler()
    compiler.ingest(builtInFilterList)
    print("built-in list: \(compiler.ruleCountSoFar) rules")
    for file in files {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            print("  ! could not read \(file.lastPathComponent)")
            continue
        }
        let before = compiler.ruleCountSoFar
        let skippedBefore = compiler.skippedCount
        compiler.ingest(text)
        print("\(file.lastPathComponent): +\(compiler.ruleCountSoFar - before) rules, "
            + "\(compiler.skippedCount - skippedBefore) lines skipped")
    }
    if files.isEmpty {
        print("no subscriptions on disk — run the app once, or drop .txt lists in\n  \(listsURL.path)")
    }

    let set = compiler.finish(allowlist: ["allowed.example"])
    print("\ntotal: \(set.ruleCount) rules, \(set.droppedCount) dropped over the cap, "
        + "\(set.skippedCount) lines skipped, \(set.json.count.formatted()) bytes of JSON")

    guard let store = WKContentRuleListStore.default() else {
        print("✗ no rule-list store")
        exit(1)
    }
    let identifier = "chromeless-compiletest"
    let started = Date()
    var status: Int32 = 1
    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: set.json) { list, error in
        if let error {
            print("✗ WebKit refused the list: \(error.localizedDescription)")
        } else if list != nil {
            print("✓ compiled in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            status = 0
        }
        store.removeContentRuleList(forIdentifier: identifier) { _ in
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
    CFRunLoopRun()
    exit(status)
}
