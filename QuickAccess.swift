import Cocoa
import WebKit

// MARK: - Quick access
//
// Ten shortcuts on the start page. Each one is a title, a URL, and an icon the
// app goes and fetches from the site itself once the shortcut is saved — the
// user is never asked for artwork. Icons are stored inline as base64 PNG data
// URIs because the start page is handed to WebKit as a string with no base URL,
// so it has no origin to load a file or a remote image from.

extension Notification.Name {
    static let quickAccessDidChange = Notification.Name("chromeless.quickAccessDidChange")
}

struct QuickLink: Codable, Equatable {
    var id: String
    var title: String
    var url: String
    /// `data:image/png;base64,…`, or nil while the fetch is in flight or after
    /// it failed. The page falls back to a monogram.
    var icon: String?
}

struct QuickAccessArchive: Codable {
    var links: [QuickLink]
    /// Optional so a file written before the section could be folded still
    /// decodes; a missing key just means "open".
    var collapsed: Bool?
}

final class QuickAccessStore {
    static let shared = QuickAccessStore()
    static let slotCount = 10

    private(set) var links: [QuickLink] = []
    private(set) var collapsed = false
    private let directoryURL: URL
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directoryURL = appSupport.appendingPathComponent("Chromeless", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("quickaccess.json")
        load()
    }

    func link(id: String) -> QuickLink? { links.first { $0.id == id } }

    /// The array the start page renders, ready to paste into its script.
    var payloadJSON: String {
        let items: [[String: Any]] = links.map { link in
            var item: [String: Any] = ["id": link.id, "title": link.title, "url": link.url]
            if let icon = link.icon { item["icon"] = icon }
            return item
        }
        let payload: [String: Any] = ["slots": Self.slotCount, "links": items, "collapsed": collapsed]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"slots\":\(Self.slotCount),\"links\":[],\"collapsed\":false}"
        }
        // Titles come off arbitrary web pages and this JSON is pasted inside a
        // <script> tag, so no character that could close it survives the trip.
        return json
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
    }

    /// Adds a shortcut, or rewrites the one already at `id`. A blank title is
    /// left blank on purpose: the icon fetch fills it in from the page's own
    /// `<title>` a moment later.
    @discardableResult
    func save(id: String?, title: String, url: URL) -> QuickLink? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = url.absoluteString
        var fallback = url.host ?? address
        if fallback.hasPrefix("www.") { fallback.removeFirst(4) }

        if let id, let index = links.firstIndex(where: { $0.id == id }) {
            let addressChanged = links[index].url != address
            links[index].title = cleanTitle.isEmpty ? fallback : cleanTitle
            links[index].url = address
            // A shortcut pointed somewhere new needs the new site's icon.
            if addressChanged { links[index].icon = nil }
            persist()
            if addressChanged || cleanTitle.isEmpty { refreshIcon(for: links[index], keepTitle: !cleanTitle.isEmpty) }
            return links[index]
        }

        guard links.count < Self.slotCount else { return nil }
        let link = QuickLink(
            id: UUID().uuidString,
            title: cleanTitle.isEmpty ? fallback : cleanTitle,
            url: address,
            icon: nil)
        links.append(link)
        persist()
        refreshIcon(for: link, keepTitle: !cleanTitle.isEmpty)
        return link
    }

    func setCollapsed(_ value: Bool) {
        guard collapsed != value else { return }
        collapsed = value
        persist()
    }

    func remove(id: String) {
        guard links.contains(where: { $0.id == id }) else { return }
        links.removeAll { $0.id == id }
        persist()
    }

    // MARK: Icons

    /// Fetches the site's icon (and, when the user left it blank, its title)
    /// off the main thread, then folds the result back in — but only if the
    /// shortcut still exists and still points at the same URL, since the user
    /// may have edited or deleted it while the network was busy.
    private func refreshIcon(for link: QuickLink, keepTitle: Bool) {
        guard let url = URL(string: link.url) else { return }
        let id = link.id
        let address = link.url
        QuickAccessIconFetcher.fetch(for: url) { [weak self] icon, pageTitle in
            guard let self else { return }
            guard let index = self.links.firstIndex(where: { $0.id == id }),
                  self.links[index].url == address else { return }
            var changed = false
            if let icon { self.links[index].icon = icon; changed = true }
            if !keepTitle, let pageTitle, !pageTitle.isEmpty {
                self.links[index].title = pageTitle
                changed = true
            }
            guard changed else { return }
            self.persist()
        }
    }

    /// Re-fetches every icon the app does not have yet. Called at launch so a
    /// shortcut saved while offline picks its icon up later.
    func refreshMissingIcons() {
        for link in links where link.icon == nil { refreshIcon(for: link, keepTitle: true) }
    }

    // MARK: Disk

    private func load() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let data = try Data(contentsOf: fileURL)
            let archive = try JSONDecoder().decode(QuickAccessArchive.self, from: data)
            links = archive.links
            collapsed = archive.collapsed ?? false
            if links.count > Self.slotCount { links.removeSubrange(Self.slotCount...) }
        } catch {
            fputs("chromeless: could not load quick access: \(error.localizedDescription)\n", stderr)
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(QuickAccessArchive(links: links, collapsed: collapsed))
                .write(to: fileURL, options: .atomic)
        } catch {
            fputs("chromeless: could not save quick access: \(error.localizedDescription)\n", stderr)
        }
        NotificationCenter.default.post(name: .quickAccessDidChange, object: nil)
    }
}

let quickAccessStore = QuickAccessStore.shared

// MARK: - Icon fetching

enum QuickAccessIconFetcher {
    private static let side = 64
    private static let session: URLSession = {
        let conf = URLSessionConfiguration.ephemeral
        conf.timeoutIntervalForRequest = 8
        conf.timeoutIntervalForResource = 15
        conf.httpAdditionalHeaders = ["User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"]
        return URLSession(configuration: conf)
    }()

    /// Calls back on the main queue with a data URI and the page's own title.
    /// Either may be nil; a site with no reachable icon is not an error.
    static func fetch(for url: URL, completion: @escaping (String?, String?) -> Void) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            DispatchQueue.main.async { completion(nil, nil) }
            return
        }
        session.dataTask(with: url) { data, _, _ in
            let html = data.flatMap { String(data: $0.prefix(400_000), encoding: .utf8) }
                ?? data.flatMap { String(data: $0.prefix(400_000), encoding: .isoLatin1) }
            let head = html.map { String($0.prefix(upTo: $0.range(of: "</head>", options: .caseInsensitive)?.upperBound ?? $0.endIndex)) }
            var candidates = head.map { declaredIcons(in: $0, page: url) } ?? []
            // Every site is meant to answer /favicon.ico even when it declares
            // nothing, so it is the last thing tried rather than the first.
            if let root = URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL {
                candidates.append(root)
            }
            download(candidates, at: 0) { icon in
                DispatchQueue.main.async { completion(icon, head.flatMap { pageTitle(in: $0) }) }
            }
        }.resume()
    }

    /// `<link rel="… icon …">` in document order, best first. Bigger wins, and
    /// a vector icon sorts last because NSImage cannot always decode one.
    private static func declaredIcons(in head: String, page: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: "<link\\s[^>]*>", options: [.caseInsensitive]) else { return [] }
        let range = NSRange(head.startIndex..., in: head)
        var scored: [(url: URL, score: Int, order: Int)] = []
        for (order, match) in regex.matches(in: head, range: range).enumerated() {
            guard let tagRange = Range(match.range, in: head) else { continue }
            let tag = String(head[tagRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.split(separator: " ").contains(where: { $0 == "icon" || $0 == "shortcut" || $0 == "apple-touch-icon" || $0 == "apple-touch-icon-precomposed" }),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: page)?.absoluteURL else { continue }
            var score = declaredSize(attribute("sizes", in: tag)) ?? (rel.contains("apple-touch-icon") ? 180 : 32)
            if url.pathExtension.lowercased() == "svg" { score = 1 }
            scored.append((url, min(score, 512), order))
        }
        return scored.sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }
            .map { $0.url }
    }

    private static func declaredSize(_ sizes: String?) -> Int? {
        guard let sizes else { return nil }
        return sizes.lowercased().split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { Int($0.split(separator: "x").first ?? "") }.max()
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
            options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for group in 2...4 {
            if let r = Range(match.range(at: group), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    private static func pageTitle(in head: String) -> String? {
        guard let open = head.range(of: "<title", options: .caseInsensitive),
              let gt = head.range(of: ">", range: open.upperBound..<head.endIndex),
              let close = head.range(of: "</title>", options: .caseInsensitive, range: gt.upperBound..<head.endIndex)
        else { return nil }
        let raw = String(head[gt.upperBound..<close.lowerBound])
        let text = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(60))
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                      ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                      ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–")] {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return out
    }

    /// Walks the candidates one at a time and stops at the first that decodes.
    private static func download(_ urls: [URL], at index: Int, completion: @escaping (String?) -> Void) {
        guard index < urls.count, index < 5 else { completion(nil); return }
        session.dataTask(with: urls[index]) { data, response, _ in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            if ok, let data, data.count < 2 * 1024 * 1024, let icon = encode(data) {
                completion(icon)
            } else {
                download(urls, at: index + 1, completion: completion)
            }
        }.resume()
    }

    /// Redraws whatever came back as a square 64pt PNG, so a 1 MB apple-touch
    /// icon does not end up inlined in the JSON at full size.
    private static func encode(_ data: Data) -> String? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)

        let scale = min(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = NSPoint(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: origin, size: drawn),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}

// MARK: - Page bridge

// Same shape as `AuxClickRouter`: one handler for every web view, routed by the
// view the message came from, so it never needs to know the window or profile.
final class QuickAccessRouter: NSObject, WKScriptMessageHandler {
    static let shared = QuickAccessRouter()
    static let messageName = "chromelessQuickAccess"

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? BrowserWebView,
              let body = message.body as? [String: Any] else { return }
        webView.onQuickAccess?(webView, body)
    }
}
