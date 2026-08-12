// AdBlockFilters.swift — the built-in filter list, and the converter that turns
// AdBlock Plus filter syntax into the JSON WebKit's content blocker understands.
//
// Everything the blocker knows arrives here as ABP text: the built-in list
// below, downloaded subscriptions, rules the user typed, and selectors the
// element picker produced. One converter means one set of edge cases.
//
// WebKit's url-filter is a *restricted* regular expression. It takes `.`, `*`,
// `+`, `?`, `^`, `$`, `[...]`, `[^...]`, `(...)`, `|` and backslash escapes, and
// rejects `\d`, `\w`, `\b`, `{n,m}`, lookahead and backreferences. One rejected
// rule fails the whole compile, so the generator only ever emits the safe
// subset and drops anything it cannot vouch for.

import Foundation

// MARK: - WebKit rule model

struct WebKitTrigger: Encodable {
    var urlFilter: String
    var caseSensitive: Bool?
    var resourceType: [String]?
    var loadType: [String]?
    var ifDomain: [String]?
    var unlessDomain: [String]?

    enum CodingKeys: String, CodingKey {
        case urlFilter = "url-filter"
        case caseSensitive = "url-filter-is-case-sensitive"
        case resourceType = "resource-type"
        case loadType = "load-type"
        case ifDomain = "if-domain"
        case unlessDomain = "unless-domain"
    }
}

struct WebKitAction: Encodable {
    var type: String
    var selector: String?
}

struct WebKitRule: Encodable {
    var trigger: WebKitTrigger
    var action: WebKitAction
}

// MARK: - Conversion result

struct CompiledRuleSet {
    var json: String
    var ruleCount: Int
    var droppedCount: Int   // over the cap, reported rather than dropped silently
    var skippedCount: Int   // filter lines the converter could not express
}

// MARK: - Converter

// Accumulates filter text from several sources, then emits one rule array.
// Order is fixed and load-bearing: block rules, then hiding rules, then `@@`
// exceptions, then the per-site allowlist. `ignore-previous-rules` only cancels
// rules earlier in the same list, so the two kinds of unblocking have to come
// last, in that order.
struct FilterCompiler {
    // Bumped whenever conversion changes, so a cached compiled list built by an
    // older converter is not reused after an update.
    static let version = 1
    // WebKit's own ceiling. EasyList, EasyPrivacy and ABPVN together convert to
    // about 114k rules, so in practice nothing is dropped; the cap exists so a
    // pathological subscription cannot take the compile down. Exceptions and the
    // allowlist are reserved out of it and never dropped.
    static let ruleLimit = 150_000
    static let selectorsPerRule = 500

    private var blockRules: [WebKitRule] = []
    private var exceptionRules: [WebKitRule] = []
    private var cosmetic: [CosmeticScope: [String]] = [:]
    private var cosmeticOrder: [CosmeticScope] = []
    private var seen = Set<String>()
    private(set) var skippedCount = 0

    private struct CosmeticScope: Hashable {
        var ifDomain: [String]
        var unlessDomain: [String]
    }

    // What has been ingested so far, so a caller feeding several sources can
    // attribute rules to the source that contributed them. Hiding selectors are
    // counted individually here; they are merged into far fewer rules later.
    var ruleCountSoFar: Int {
        blockRules.count + exceptionRules.count + cosmetic.values.reduce(0) { $0 + $1.count }
    }

    // MARK: Ingestion

    mutating func ingest(_ text: String) {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            ingest(line: raw.trimmingCharacters(in: .whitespaces))
        }
    }

    private mutating func ingest(line: String) {
        if line.isEmpty { return }
        // Comments and the `[Adblock Plus 2.0]` header.
        if line.hasPrefix("!") || line.hasPrefix("#!") || line.hasPrefix("[") { return }
        // A bare `# comment` is not valid ABP but appears in hand-written lists.
        if line.hasPrefix("# ") { return }

        // Extended cosmetic syntax needs a script engine chromeless does not
        // have. Checked before the plain `##` case, since `#?#` contains no `##`
        // but `##+js(` does.
        for marker in ["#@#", "#@?#", "#%#", "#$#", "#?#", "#$?#"] where line.contains(marker) {
            skippedCount += 1
            return
        }
        if line.contains("##+js(") || line.contains("##^") {
            skippedCount += 1
            return
        }
        if let range = line.range(of: "##") {
            ingestCosmetic(domains: String(line[line.startIndex..<range.lowerBound]),
                           selector: String(line[range.upperBound...]))
            return
        }
        ingestNetwork(line)
    }

    // MARK: Cosmetic rules

    private mutating func ingestCosmetic(domains: String, selector rawSelector: String) {
        let selector = rawSelector.trimmingCharacters(in: .whitespaces)
        guard Self.isSafeSelector(selector) else { skippedCount += 1; return }

        var ifDomain: [String] = []
        var unlessDomain: [String] = []
        for entry in domains.split(separator: ",") {
            let text = entry.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("~") {
                guard let d = Self.normalizedDomain(String(text.dropFirst())) else { continue }
                unlessDomain.append("*" + d)
            } else {
                guard let d = Self.normalizedDomain(text) else { continue }
                ifDomain.append("*" + d)
            }
        }
        // A rule scoped only to domains the converter could not express would
        // apply everywhere — far worse than not applying at all.
        if ifDomain.isEmpty && !domains.isEmpty && !domains.hasPrefix("~") {
            skippedCount += 1
            return
        }

        let scope = CosmeticScope(ifDomain: ifDomain.sorted(), unlessDomain: unlessDomain.sorted())
        if cosmetic[scope] == nil {
            cosmetic[scope] = []
            cosmeticOrder.append(scope)
        }
        cosmetic[scope]?.append(selector)
    }

    // WebKit validates every selector at compile time and fails the entire list
    // on the first one it cannot parse, so anything procedural or exotic is
    // turned away here rather than risking the whole build.
    private static let unsafeSelectorMarkers = [
        ":has(", ":has-text(", ":matches-css", ":contains(", ":style(", ":remove(",
        ":upward(", ":xpath(", ":nth-ancestor(", ":watch-attr(", ":if(", ":if-not(",
        ":min-text-length(", ":matches-path(", ":matches-attr(", ":others(",
        "/*", "{", "}",
    ]

    static func isSafeSelector(_ selector: String) -> Bool {
        if selector.isEmpty || selector.count > 500 { return false }
        // CSS escapes (`.md\:hidden`) are legal but a frequent source of
        // compile failures, and one bad selector costs the entire list.
        if selector.contains("\\") { return false }
        for marker in unsafeSelectorMarkers where selector.contains(marker) { return false }
        // A selector has to start with something that can be a subject.
        guard let first = selector.first, first != ">", first != "+", first != "~" else { return false }
        return true
    }

    // MARK: Network rules

    private mutating func ingestNetwork(_ line: String) {
        var body = line
        var isException = false
        if body.hasPrefix("@@") {
            isException = true
            body = String(body.dropFirst(2))
        }

        let (pattern, optionText) = Self.splitOptions(body)
        let options = FilterOptions(optionText)
        if options.unsupported { skippedCount += 1; return }
        // `$elemhide` and friends only mean something as an exception. As a
        // blocking rule they carry no resource type, and letting one through
        // would block every request matching the pattern.
        if !isException && options.documentScoped && options.resourceTypes == nil {
            skippedCount += 1
            return
        }

        // `@@||site^$document` (and its elemhide cousins) means "turn the
        // blocker off on this site", not "let this one request through". It maps
        // to an unconditional cancel scoped to the page's domain.
        if isException && options.documentScoped {
            guard let domain = Self.domainAnchor(of: pattern) else { skippedCount += 1; return }
            append(WebKitRule(
                trigger: WebKitTrigger(urlFilter: ".*", ifDomain: ["*" + domain]),
                action: WebKitAction(type: "ignore-previous-rules")),
                exception: true)
            return
        }

        guard let filter = Self.urlFilter(from: pattern) else { skippedCount += 1; return }

        let trigger = WebKitTrigger(
            urlFilter: filter,
            caseSensitive: options.caseSensitive ? true : nil,
            resourceType: options.resourceTypes,
            loadType: options.loadType,
            ifDomain: options.ifDomains.isEmpty ? nil : options.ifDomains,
            unlessDomain: options.unlessDomains.isEmpty ? nil : options.unlessDomains)
        append(WebKitRule(
            trigger: trigger,
            action: WebKitAction(type: isException ? "ignore-previous-rules" : "block")),
            exception: isException)
    }

    private mutating func append(_ rule: WebKitRule, exception: Bool) {
        let key = Self.dedupeKey(rule)
        guard seen.insert(key).inserted else { return }
        if exception { exceptionRules.append(rule) } else { blockRules.append(rule) }
    }

    private static func dedupeKey(_ rule: WebKitRule) -> String {
        let t = rule.trigger
        return [
            t.urlFilter,
            t.resourceType?.joined(separator: "+") ?? "",
            t.loadType?.joined(separator: "+") ?? "",
            t.ifDomain?.joined(separator: "+") ?? "",
            t.unlessDomain?.joined(separator: "+") ?? "",
            rule.action.type,
        ].joined(separator: "\u{1}")
    }

    // MARK: Emission

    // `allowlist` holds registrable domains the user switched blocking off for.
    func finish(allowlist: [String]) -> CompiledRuleSet {
        var hiding: [WebKitRule] = []
        for scope in cosmeticOrder {
            guard let selectors = cosmetic[scope] else { continue }
            // One rule per selector would spend tens of thousands of rules on
            // EasyList alone; WebKit takes a selector list, so they are merged.
            for batch in stride(from: 0, to: selectors.count, by: Self.selectorsPerRule) {
                let slice = selectors[batch..<min(batch + Self.selectorsPerRule, selectors.count)]
                hiding.append(WebKitRule(
                    trigger: WebKitTrigger(
                        urlFilter: ".*",
                        ifDomain: scope.ifDomain.isEmpty ? nil : scope.ifDomain,
                        unlessDomain: scope.unlessDomain.isEmpty ? nil : scope.unlessDomain),
                    action: WebKitAction(type: "css-display-none",
                                         selector: slice.joined(separator: ", "))))
            }
        }

        let allowRules: [WebKitRule] = allowlist.compactMap { domain in
            guard let d = Self.normalizedDomain(domain) else { return nil }
            return WebKitRule(
                trigger: WebKitTrigger(urlFilter: ".*", ifDomain: ["*" + d]),
                action: WebKitAction(type: "ignore-previous-rules"))
        }

        // The last two groups are what keeps sites working, so the cap eats into
        // the blocking rules instead — tail first, which is the lowest-priority
        // subscription, because sources are ingested in priority order.
        var exceptions = exceptionRules
        var reserved = exceptions.count + allowRules.count
        var dropped = 0
        if reserved > Self.ruleLimit {
            let room = max(0, Self.ruleLimit - allowRules.count)
            dropped += exceptions.count - room
            exceptions = Array(exceptions.prefix(room))
            reserved = exceptions.count + allowRules.count
        }
        var body = blockRules + hiding
        let budget = max(0, Self.ruleLimit - reserved)
        if body.count > budget {
            dropped += body.count - budget
            body = Array(body.prefix(budget))
        }

        let rules = body + exceptions + allowRules
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(rules)) ?? Data("[]".utf8)
        return CompiledRuleSet(
            json: String(data: data, encoding: .utf8) ?? "[]",
            ruleCount: rules.count,
            droppedCount: dropped,
            skippedCount: skippedCount)
    }

    // MARK: Pattern translation

    private static let regexSpecials = Set<Character>("\\^$.|?*+()[]{}")
    // ABP's `^` separator: anything that ends a URL component. A following
    // character is required, which is safe because WebKit matches canonicalized
    // URLs — `https://ads.com` already carries its trailing slash by then.
    private static let separatorClass = "[/?#:&=;,]"

    static func urlFilter(from rawPattern: String) -> String? {
        var pattern = rawPattern
        if pattern.isEmpty || pattern == "*" { return ".*" }

        // A `/…/` rule is a raw regex. Pass it through only if it stays inside
        // the subset WebKit implements.
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 2 {
            let inner = String(pattern.dropFirst().dropLast())
            // `|` is the one that bites: WebKit's parser answers "Disjunctions
            // are not supported yet" and fails the whole list, not just the rule.
            for bad in ["\\d", "\\w", "\\s", "\\D", "\\W", "\\S", "\\b", "\\B", "(?", "{", "|"]
            where inner.contains(bad) { return nil }
            return isValidRegex(inner) ? inner : nil
        }

        var anchorDomain = false
        var anchorStart = false
        var anchorEnd = false
        if pattern.hasPrefix("||") {
            anchorDomain = true
            pattern.removeFirst(2)
        } else if pattern.hasPrefix("|") {
            anchorStart = true
            pattern.removeFirst()
        }
        if pattern.hasSuffix("|") {
            anchorEnd = true
            pattern.removeLast()
        }
        // A leading or trailing `*` says "anything here", which an unanchored
        // pattern already allows.
        while pattern.hasPrefix("*") { pattern.removeFirst() }
        while pattern.hasSuffix("*") { pattern.removeLast(); anchorEnd = false }
        if pattern.isEmpty { return anchorDomain ? "^https?://" : ".*" }

        var body = ""
        for ch in pattern {
            switch ch {
            case "*": body += ".*"
            case "^": body += separatorClass
            default:
                if regexSpecials.contains(ch) { body.append("\\") }
                body.append(ch)
            }
        }

        var filter = body
        if anchorDomain {
            filter = "^https?://([^/?#]*\\.)?" + body
        } else if anchorStart {
            filter = "^" + body
        }
        if anchorEnd { filter += "$" }
        return isValidRegex(filter) ? filter : nil
    }

    // `||example.com^` and friends — the domain an exception rule is scoped to.
    static func domainAnchor(of pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var rest = String(pattern.dropFirst(2))
        if let cut = rest.firstIndex(where: { "^/*|?".contains($0) }) {
            rest = String(rest[rest.startIndex..<cut])
        }
        return normalizedDomain(rest)
    }

    // ICU is stricter than WebKit in places and laxer in others, but it reliably
    // catches the unbalanced brackets and stray quantifiers that would otherwise
    // take the whole compile down.
    private static func isValidRegex(_ pattern: String) -> Bool {
        if pattern.isEmpty { return false }
        return (try? NSRegularExpression(pattern: pattern)) != nil
    }

    static func normalizedDomain(_ raw: String) -> String? {
        var d = raw.trimmingCharacters(in: .whitespaces).lowercased()
        while d.hasPrefix(".") { d.removeFirst() }
        while d.hasSuffix(".") { d.removeLast() }
        if d.isEmpty || d.count > 253 { return nil }
        // WebKit's if-domain takes a literal domain (optionally `*`-prefixed for
        // subdomains); wildcards and regex entries have nowhere to go.
        if d.contains("*") || d.contains("/") || d.contains(" ") || d.contains("~") { return nil }
        guard d.contains(".") else { return nil }
        // WebKit wants if-domain entries in lowercase ASCII or punycode and
        // fails the compile on anything else, so a non-ASCII domain is dropped
        // rather than guessed at.
        for scalar in d.unicodeScalars {
            let ok = (scalar.value >= 97 && scalar.value <= 122)   // a-z
                || (scalar.value >= 48 && scalar.value <= 57)      // 0-9
                || scalar == "." || scalar == "-"
            if !ok { return nil }
        }
        return d
    }

    // Options are a suffix after `$`. Patterns rarely contain one, and when the
    // suffix does not look like an option list it is treated as part of the
    // pattern instead of throwing the rule away.
    static func splitOptions(_ body: String) -> (pattern: String, options: String) {
        guard let dollar = body.lastIndex(of: "$") else { return (body, "") }
        // `/…$/` is a regex anchor, not an option separator.
        if body.hasPrefix("/"), let lastSlash = body.lastIndex(of: "/"), lastSlash > dollar {
            return (body, "")
        }
        let suffix = String(body[body.index(after: dollar)...])
        if suffix.isEmpty { return (String(body[body.startIndex..<dollar]), "") }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyz0123456789-_,=~.|*/:")
        if suffix.rangeOfCharacter(from: allowed.inverted) != nil { return (body, "") }
        return (String(body[body.startIndex..<dollar]), suffix)
    }
}

// MARK: - Filter options

struct FilterOptions {
    var resourceTypes: [String]?
    var loadType: [String]?
    var ifDomains: [String] = []
    var unlessDomains: [String] = []
    var caseSensitive = false
    var documentScoped = false
    var unsupported = false

    // `document` and `popup` are left out of the complement on purpose: a
    // `$~script` rule is about subresources, and letting it cancel main-frame
    // navigations would take whole pages down.
    static let complementTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media"]

    static let typeMap: [String: String] = [
        "script": "script",
        "image": "image",
        "background": "image",
        "stylesheet": "style-sheet",
        "css": "style-sheet",
        "font": "font",
        "media": "media",
        "popup": "popup",
        "subdocument": "document",
        "frame": "document",
        "document": "document",
        "doc": "document",
        "xmlhttprequest": "raw",
        "xhr": "raw",
        "websocket": "raw",
        "ping": "raw",
        "beacon": "raw",
        "other": "raw",
        "object": "raw",
        "object-subrequest": "raw",
    ]

    // Modifiers that rewrite, inject, or otherwise do something WebKit's engine
    // simply cannot. A rule carrying one is dropped rather than approximated.
    static let unsupportedOptions: Set<String> = [
        "csp", "redirect", "redirect-rule", "rewrite", "removeparam", "queryprune",
        "badfilter", "header", "replace", "method", "denyallow", "to", "from",
        "strict1p", "strict3p", "inline-script", "inline-font", "empty", "mp4",
        "stealth", "cookie", "network", "app", "permissions", "urltransform",
        "uritransform", "ipaddress", "referrerpolicy", "webrtc", "jsonprune", "hls",
    ]

    // Priority modifiers. WebKit has no notion of one rule outranking another,
    // so these are dropped and the rule kept as an ordinary block — losing the
    // priority is much cheaper than losing the rule.
    static let ignoredOptions: Set<String> = ["important", "all"]

    // Modifiers that scope an exception to a whole page rather than one request.
    static let documentOptions: Set<String> = [
        "document", "elemhide", "generichide", "specifichide", "genericblock", "ehide",
    ]

    // Sets `unsupported` rather than failing, so the caller decides whether a
    // rule it cannot express is worth counting.
    init(_ text: String) {
        if text.isEmpty { return }
        var included: [String] = []
        var excluded = Set<String>()

        for rawToken in text.split(separator: ",") {
            var token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
            if token.isEmpty { continue }

            if token.hasPrefix("domain=") {
                for entry in token.dropFirst("domain=".count).split(separator: "|") {
                    let value = String(entry)
                    if value.hasPrefix("~") {
                        if let d = FilterCompiler.normalizedDomain(String(value.dropFirst())) {
                            unlessDomains.append("*" + d)
                        }
                    } else if let d = FilterCompiler.normalizedDomain(value) {
                        ifDomains.append("*" + d)
                    }
                }
                continue
            }
            if token == "match-case" { caseSensitive = true; continue }
            if token == "third-party" || token == "3p" { loadType = ["third-party"]; continue }
            if token == "~third-party" || token == "first-party" || token == "1p" {
                loadType = ["first-party"]
                continue
            }
            // Every remaining `key=value` modifier rewrites the request rather
            // than deciding it, which this engine cannot do.
            if token.contains("=") { unsupported = true; return }

            var negated = false
            if token.hasPrefix("~") { negated = true; token.removeFirst() }

            if Self.ignoredOptions.contains(token) { continue }
            if Self.documentOptions.contains(token) && !negated {
                documentScoped = true
                if let mapped = Self.typeMap[token] { included.append(mapped) }
                continue
            }
            if Self.unsupportedOptions.contains(token) { unsupported = true; return }
            guard let mapped = Self.typeMap[token] else { unsupported = true; return }
            if negated { excluded.insert(mapped) } else { included.append(mapped) }
        }

        if !included.isEmpty {
            resourceTypes = Array(Set(included)).sorted()
        } else if !excluded.isEmpty {
            let remaining = Self.complementTypes.filter { !excluded.contains($0) }
            resourceTypes = remaining.isEmpty ? nil : remaining.sorted()
        }
    }
}

// MARK: - Registrable domain

// A public-suffix list would be 200 KB of data for a job that two rules of thumb
// get right almost everywhere: take the last two labels, unless the second-last
// is one of the well-known second-level suffixes, in which case take three. It
// decides what `⇧⌘B` switches off, so being wrong means the toggle covers a
// slightly wider or narrower slice of one site — not a correctness failure.
private let secondLevelSuffixes: Set<String> = [
    "co", "com", "net", "org", "edu", "gov", "mil", "ac", "or", "ne", "go", "in",
    "info", "biz", "name", "id", "sch", "gen", "ltd", "plc", "web", "blogspot",
]

func registrableDomain(for host: String) -> String? {
    let clean = host.lowercased().trimmingCharacters(in: .whitespaces)
    guard !clean.isEmpty, clean.contains(".") else { return clean.isEmpty ? nil : clean }
    // Bare IPv4 addresses have no registrable domain; treat them whole.
    if clean.allSatisfy({ $0.isNumber || $0 == "." }) { return clean }
    let labels = clean.split(separator: ".").map(String.init)
    guard labels.count > 2 else { return clean }
    if secondLevelSuffixes.contains(labels[labels.count - 2]), labels.count >= 3 {
        return labels.suffix(3).joined(separator: ".")
    }
    return labels.suffix(2).joined(separator: ".")
}

// MARK: - Built-in list

// Deliberately conservative. Every rule here is one that blocks advertising or
// tracking without taking a feature down with it, which is why some obvious
// candidates are missing: googletagmanager.com routinely carries a site's own
// functionality, and connect.facebook.net is how "Log in with Facebook" works.
// Wide coverage is what the subscriptions are for; this list is the floor.
let builtInFilterList = """
! chromeless built-in filters

! ── Google advertising ────────────────────────────────────────────────
||doubleclick.net^$third-party
||googlesyndication.com^$third-party
||googleadservices.com^$third-party
||googletagservices.com^$third-party
||adservice.google.com^
||adservice.google.*/adsid/
||pagead2.googlesyndication.com^
||partner.googleadservices.com^
||securepubads.g.doubleclick.net^
||pubads.g.doubleclick.net^
||googleads.g.doubleclick.net^
||stats.g.doubleclick.net^
||cm.g.doubleclick.net^
||ad.doubleclick.net^
||static.doubleclick.net^
||afs.googleusercontent.com^
||google.com/pagead/$third-party
||google.com/adsense/$third-party
||google.com/uds/afs^
||google.com/afs/ads^

! ── Analytics and measurement ─────────────────────────────────────────
||google-analytics.com^
||analytics.google.com^
||ssl.google-analytics.com^
||scorecardresearch.com^$third-party
||quantserve.com^$third-party
||quantcast.com^$third-party
||chartbeat.com^$third-party
||chartbeat.net^$third-party
||hotjar.com^$third-party
||hotjar.io^$third-party
||mixpanel.com^$third-party
||segment.io^$third-party
||segment.com/analytics.js^$third-party
||amplitude.com^$third-party
||fullstory.com^$third-party
||mouseflow.com^$third-party
||crazyegg.com^$third-party
||luckyorange.com^$third-party
||clarity.ms^$third-party
||newrelic.com^$third-party
||nr-data.net^$third-party
||statcounter.com^$third-party
||histats.com^$third-party
||yandex.ru/metrika^$third-party
||mc.yandex.ru^$third-party
||hm.baidu.com^$third-party

! ── Social and retargeting pixels ─────────────────────────────────────
||facebook.com/tr^
||facebook.com/tr/^
||analytics.tiktok.com^
||ads.tiktok.com^
||ads-api.tiktok.com^
||analytics.twitter.com^
||ads-twitter.com^
||static.ads-twitter.com^
||sc-static.net/scevent^
||tr.snapchat.com^
||ads.linkedin.com^
||px.ads.linkedin.com^
||bat.bing.com^
||pinterest.com/ct.html^
||ct.pinterest.com^

! ── Ad exchanges and supply-side platforms ────────────────────────────
||criteo.com^$third-party
||criteo.net^$third-party
||pubmatic.com^$third-party
||rubiconproject.com^$third-party
||adnxs.com^$third-party
||adnxs-simple.com^$third-party
||openx.net^$third-party
||adform.net^$third-party
||adformdsp.net^$third-party
||smartadserver.com^$third-party
||casalemedia.com^$third-party
||indexww.com^$third-party
||lijit.com^$third-party
||sovrn.com^$third-party
||media.net^$third-party
||contextweb.com^$third-party
||bidswitch.net^$third-party
||adsrvr.org^$third-party
||360yield.com^$third-party
||districtm.io^$third-party
||sharethrough.com^$third-party
||triplelift.com^$third-party
||yieldmo.com^$third-party
||gumgum.com^$third-party
||teads.tv^$third-party
||spotxchange.com^$third-party
||spotx.tv^$third-party
||zedo.com^$third-party
||adroll.com^$third-party
||adsymptotic.com^$third-party
||advertising.com^$third-party
||adtechus.com^$third-party
||amazon-adsystem.com^$third-party
||servedbyadbutler.com^$third-party
||adzerk.net^$third-party
||moatads.com^$third-party
||doubleverify.com^$third-party
||adsafeprotected.com^$third-party
||outbrain.com^$third-party
||taboola.com^$third-party
||taboolasyndication.com^$third-party
||mgid.com^$third-party
||dable.io^$third-party
||revcontent.com^$third-party
||plista.com^$third-party
||zergnet.com^$third-party

! ── Pop-ups, redirects, and the low end of the market ─────────────────
||popads.net^
||popcash.net^
||propellerads.com^
||propellerclick.com^
||adcash.com^
||exoclick.com^
||exosrv.com^
||juicyads.com^
||trafficjunky.net^
||adsterra.com^
||hilltopads.net^
||clickadu.com^
||onclickmax.com^
||mgid.co^
||bidvertiser.com^
||adf.ly^
||shorte.st^

! ── Consent walls and paywall nags that are pure ad plumbing ──────────
||cookielaw.org^$third-party
||cookiebot.com^$third-party
||onetrust.com^$third-party
||quantcast.mgr.consensu.org^

! ── Vietnamese ad networks ────────────────────────────────────────────
||admicro.vn^$third-party
||admicro1.vcmedia.vn^
||admicro2.vcmedia.vn^
||media1.admicro.vn^
||adi.admicro.vn^
||delivery.admicro.vn^
||log.admicro.vn^
||adtima.vn^$third-party
||adtimaserver.vn^$third-party
||static.adtimaserver.vn^
||eclick.vn^
||adtracking.vn^
||novanet.vn^$third-party
||ants.vn^$third-party
||adnet.vn^$third-party
||blueseed.tv^$third-party
||mediaon.vn^$third-party
||adsplay.net^$third-party
||adservice.vn^$third-party
||yomedia.vn^$third-party
||adpia.vn^$third-party
||accesstrade.vn^$third-party
||masoffer.com^$third-party

! ── Generic hiding, kept small on purpose ─────────────────────────────
##.adsbygoogle
##ins.adsbygoogle
##iframe[id^="google_ads_iframe"]
##iframe[id^="google_ads_frame"]
##div[id^="div-gpt-ad"]
##div[id^="google_ads_div"]
##.trc_related_container
##.OUTBRAIN
##.taboola-widget
##div[id^="taboola-"]
##.mgbox
##div[class^="admicro"]
##div[id^="admicro"]
##div[id^="zone-admicro"]
"""

// MARK: - Self test

// `--adblock-selftest` — the repo carries no test framework, so the converter's
// escaping and option parsing are checked by a table of known conversions and a
// real compile of the built-in list. Exits non-zero on the first mismatch.
func runAdBlockSelfTest() -> Never {
    var failures = 0

    func expect(_ input: String, _ expected: String?, _ label: String) {
        let actual = FilterCompiler.urlFilter(from: input)
        if actual != expected {
            failures += 1
            print("✗ \(label)\n    input:    \(input)\n    expected: \(expected ?? "nil")\n    actual:   \(actual ?? "nil")")
        } else {
            print("✓ \(label)")
        }
    }

    expect("||example.com^", "^https?://([^/?#]*\\.)?example\\.com[/?#:&=;,]", "domain anchor + separator")
    expect("||example.com/ads/", "^https?://([^/?#]*\\.)?example\\.com/ads/", "domain anchor + path")
    expect("|http://example.com", "^http://example\\.com", "start anchor")
    expect("swf|", "swf$", "end anchor")
    expect("/banner/*.gif", "/banner/.*\\.gif", "wildcard and dot")
    expect("*", ".*", "bare wildcard")
    expect("/^https:\\/\\/ad\\d+/", nil, "regex using \\d is refused")

    func expectOptions(_ text: String, _ label: String, _ check: (FilterOptions) -> Bool) {
        if check(FilterOptions(text)) {
            print("✓ \(label)")
        } else {
            failures += 1
            print("✗ \(label)  (options: \(text))")
        }
    }

    expectOptions("third-party", "third-party maps to load-type") { $0.loadType == ["third-party"] }
    expectOptions("script,image", "type list maps to resource-type") {
        $0.resourceTypes == ["image", "script"]
    }
    expectOptions("~script", "negated type takes the complement") {
        $0.resourceTypes?.contains("script") == false && $0.resourceTypes?.isEmpty == false
    }
    expectOptions("domain=a.com|~b.com", "domain option splits both ways") {
        $0.ifDomains == ["*a.com"] && $0.unlessDomains == ["*b.com"]
    }
    expectOptions("redirect=noop.js", "rewriting options are refused") { $0.unsupported }
    expectOptions("document", "document scopes an exception") { $0.documentScoped }
    expectOptions("important", "priority modifiers keep the rule") {
        !$0.unsupported && $0.resourceTypes == nil
    }

    let domains = [("www.bbc.co.uk", "bbc.co.uk"), ("a.b.vnexpress.net", "vnexpress.net"),
                   ("shop.tiki.com.vn", "tiki.com.vn"), ("example.com", "example.com")]
    for (host, expected) in domains {
        let actual = registrableDomain(for: host)
        if actual == expected {
            print("✓ registrable domain \(host) → \(expected)")
        } else {
            failures += 1
            print("✗ registrable domain \(host): expected \(expected), got \(actual ?? "nil")")
        }
    }

    var compiler = FilterCompiler()
    compiler.ingest(builtInFilterList)
    let set = compiler.finish(allowlist: ["allowed.example"])
    print("\nbuilt-in list: \(set.ruleCount) rules, \(set.skippedCount) lines skipped, \(set.droppedCount) dropped")
    if set.ruleCount < 100 {
        failures += 1
        print("✗ built-in list produced suspiciously few rules")
    }
    guard let data = set.json.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data)) != nil else {
        print("✗ built-in list did not encode to valid JSON")
        exit(1)
    }
    print("✓ built-in list encodes to valid JSON")

    print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
    exit(failures == 0 ? 0 : 1)
}
