import Cocoa
import Security

// The three things WebKit leaves to the app: which certificate a page actually
// arrived with, whether a page may be fetched in the clear, and whether the
// window server may hand this window to a capture. They sit in one file because
// they only matter on a machine somebody else administers — a managed profile,
// a TLS-inspecting proxy, an agent watching process launches — and on such a
// machine these are the parts of the stack the user still owns.
//
// None of it stops a local process with root: page text lives in the web content
// process's memory and on the display, and root reads both. What it buys is that
// the invisible becomes visible and the cheap mistakes stop happening.

// MARK: - Certificate audit

/// What the leaf certificate says about who vouches for this connection.
/// Recorded, never enforced: WebKit evaluates server trust itself and ignores
/// any other answer, so looking and reporting is the honest thing to do here.
final class TLSAudit {
    struct Report {
        let host: String
        /// Issuer as the certificate spells it — the same fields Safari's
        /// certificate panel shows, so both can be compared by eye.
        let issuer: String
        /// Subject of every certificate in the chain, leaf first.
        let subjects: [String]
        /// Nothing in the chain is a CA macOS ships with.
        let unexpected: Bool
        /// The certificate names itself as its own issuer.
        let selfSigned: Bool
    }

    private static var reports: [String: Report] = [:]
    private static var order: [String] = []
    private static let lock = NSLock()

    static func report(for host: String?) -> Report? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return reports[host]
    }

    @discardableResult
    static func note(host: String?, trust: SecTrust?) -> Report? {
        guard let host = host?.lowercased(), !host.isEmpty, let trust else { return nil }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let subjects = chain.map { SecCertificateCopySubjectSummary($0) as String? ?? "(unnamed)" }
        let leaf = chain.first
        var issuer: (org: String?, cn: String?) = (nil, nil)
        if let leaf { issuer = issuerFields(of: leaf) }
        let issuerLine = [issuer.org.map { "O=\($0)" }, issuer.cn.map { "CN=\($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        let line = issuerLine.isEmpty ? (subjects.first ?? "unknown") : issuerLine
        let subject = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? ""
        let selfSigned = !subject.isEmpty && (issuer.cn?.caseInsensitiveCompare(subject) == .orderedSame)
        let publicCA = isPublicCA(issuer: line, subjects: subjects)
        let report = Report(host: host, issuer: line, subjects: subjects,
                            unexpected: !publicCA, selfSigned: selfSigned)
        lock.lock()
        if reports[host] == nil { order.append(host) }
        reports[host] = report
        // A session visits hundreds of hosts; the map is a cache for toasts,
        // not a log, so the oldest verdicts fall off.
        while order.count > 256 {
            reports.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        if report.unexpected {
            fputs("chromeless: \(host) is not certified by a public CA — "
                  + "issuer \(line), chain \(subjects.joined(separator: " < "))\n", stderr)
        }
        return report
    }

    /// The leaf's issuer name, read straight out of the X.509 fields. The chain's
    /// second subject says the same thing in the usual case, but WebKit does not
    /// always hand over an intermediate, and an omitted certificate is not the
    /// same as a different issuer.
    private static func issuerFields(of cert: SecCertificate) -> (org: String?, cn: String?) {
        let keys = [kSecOIDX509V1IssuerName] as CFArray
        guard let raw = SecCertificateCopyValues(cert, keys, nil) as? NSDictionary,
              let entry = raw.object(forKey: kSecOIDX509V1IssuerName) as? NSDictionary,
              let fields = entry.object(forKey: kSecPropertyKeyValue) as? [NSDictionary]
        else { return (nil, nil) }
        var org: String?
        var common: String?
        for field in fields {
            guard let label = field.object(forKey: kSecPropertyKeyLabel) as? String,
                  let value = field.object(forKey: kSecPropertyKeyValue) as? String else { continue }
            if label == "O", org == nil { org = value }
            if label == "CN", common == nil { common = value }
        }
        return (org, common)
    }

    /// Names the public roots and intermediates carry, matched as substrings.
    /// A name list rather than pinned fingerprints on purpose: every one of these
    /// rotates an intermediate yearly and a root eventually, and a pin that
    /// breaks the real site is worse than the proxy it was guarding against. A
    /// name list is a signal, not a proof — an interception CA can call itself
    /// anything — but the failure this is built to catch is the ordinary one: a
    /// corporate root with the company's name on it.
    private static let publicCANames = [
        "let's encrypt", "isrg", "digicert", "globalsign", "sectigo", "usertrust",
        "google trust services", "gts ca", "amazon", "zerossl", "cloudflare",
        "apple", "entrust", "certum", "buypass", "godaddy", "starfield",
        "microsoft", "ssl.com", "actalis", "trustasia", "identrust", "swisssign",
        "comodo", "geotrust", "thawte", "rapidssl", "verisign", "quovadis",
        "harica", "certigna", "t-systems", "deutsche telekom",
    ]

    private static func isPublicCA(issuer: String, subjects: [String]) -> Bool {
        // The leaf's issuer is the field that matters; the rest of the chain is a
        // second opinion, and it catches the case where the leaf was re-signed by
        // something wearing a name that merely looks public.
        let haystack = ([issuer] + subjects).joined(separator: "\n").lowercased()
        return publicCANames.contains { haystack.contains($0) }
    }
}

// MARK: - Unencrypted navigation

enum InsecureNavigation {
    /// Hosts a page may be fetched from in the clear: this machine, or the LAN it
    /// is plugged into. A router page or a dev server has to keep working — a
    /// guard that blocks them is a guard the user turns off for everything.
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") { return true }
        // A single label is a name only a LAN resolver answers.
        if !h.contains(".") && !h.contains(":") { return true }
        if h.contains(":") {
            // Loopback, link-local, unique-local — IPv6's answer to 10/8.
            return h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd")
        }
        let octets = h.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254), (172, 16...31):
            return true
        // CGNAT, and where Tailscale puts its peers: a fleet on 100.64/10 is
        // reachable over http for the same reason the LAN is.
        case (100, 64...127):
            return true
        default:
            return false
        }
    }

    /// The same address over TLS, for a public host typed or opened from inside
    /// the app. Nothing visible was lost — the user was not looking at that page
    /// yet — and a site that answers only on port 80 is the case the click path
    /// still asks about. An explicit port other than 80 is left alone: that is
    /// somebody's dev server or a legacy appliance, not a public site.
    static func upgradedToHTTPS(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              let host = url.host, !isLocal(host),
              url.port == nil || url.port == 80 else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        components?.port = nil
        return components?.url ?? url
    }
}

// MARK: - Capture guard

enum CaptureGuard {
    /// Tells the window server this window is not for sharing, so a per-window
    /// capture — `screencapture -l`, a screen-sharing client that grabs one
    /// window — comes back empty.
    ///
    /// Not sold as screenshot protection, because it is not one: a full-display
    /// capture, a ScreenCaptureKit client, or anything reading the framebuffer as
    /// root all ignore it, and macOS has no counterpart to Windows'
    /// `SetWindowDisplayAffinity` or Android's FLAG_SECURE. What it does buy is
    /// that the wrong window picked in a "share this window" menu shows nothing,
    /// and that a window-scoped grab has to escalate to a whole-display one to
    /// get the page — which is a thing administrators notice.
    static func apply(to window: NSWindow) {
        window.sharingType = .none
    }
}
