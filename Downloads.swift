// Downloads.swift — download management for chromeless.
//
// The window controller keeps the policy decisions (what becomes a download);
// everything after that lives here. The manager is app-lived on purpose:
// WKDownload holds its delegate weakly, so a per-window delegate dies with its
// window and takes the download with it.

import Cocoa
import WebKit

extension Notification.Name {
    static let downloadsDidChange = Notification.Name("chromeless.downloadsDidChange")
    static let downloadsMessage = Notification.Name("chromeless.downloadsMessage")
}

// MARK: - Model

enum DownloadState {
    case starting
    case running
    case paused(resumeData: Data?)
    case finished(URL)
    case failed(message: String, resumeData: Data?)

    var isActive: Bool {
        switch self {
        case .starting, .running: return true
        case .paused, .finished, .failed: return false
        }
    }
}

final class DownloadItem {
    let id = UUID()
    var filename: String
    var destination: URL?
    var sourceRequest: URLRequest?
    var download: WKDownload?
    weak var origin: WKWebView?
    var state: DownloadState = .starting
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = -1
    var wantsSavePanel: Bool
    var observations: [NSKeyValueObservation] = []

    init(filename: String, origin: WKWebView?, wantsSavePanel: Bool) {
        self.filename = filename
        self.origin = origin
        self.wantsSavePanel = wantsSavePanel
    }
}

// MARK: - Manager

final class DownloadManager: NSObject, WKDownloadDelegate {
    private(set) var items: [DownloadItem] = []
    private var broadcastScheduled = false

    var hasActiveDownloads: Bool { items.contains { $0.state.isActive } }

    // MARK: Intake

    func attach(_ download: WKDownload, from webView: WKWebView, wantsSavePanel: Bool) {
        let item = DownloadItem(
            filename: download.originalRequest?.url?.lastPathComponent ?? "download",
            origin: webView,
            wantsSavePanel: wantsSavePanel)
        item.sourceRequest = download.originalRequest
        item.download = download
        download.delegate = self
        items.insert(item, at: 0)
        observe(download, for: item)
        broadcastNow()
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    private func observe(_ download: WKDownload, for item: DownloadItem) {
        let progress = download.progress
        item.observations = [
            progress.observe(\.completedUnitCount) { [weak self, weak item] p, _ in
                guard let item else { return }
                item.bytesReceived = p.completedUnitCount
                self?.scheduleBroadcast()
            },
            progress.observe(\.totalUnitCount) { [weak self, weak item] p, _ in
                guard let item else { return }
                item.bytesExpected = p.totalUnitCount > 0 ? p.totalUnitCount : -1
                self?.scheduleBroadcast()
            },
        ]
    }

    // MARK: Actions

    func pause(_ item: DownloadItem) {
        guard item.state.isActive, let download = item.download else { return }
        // Clearing `download` first detaches the item from the delegate
        // callbacks, so the cancellation does not surface as a failure.
        item.download = nil
        item.observations.removeAll()
        download.cancel { [weak self, weak item] data in
            DispatchQueue.main.async {
                guard let item else { return }
                item.state = .paused(resumeData: data)
                self?.broadcastNow()
            }
        }
    }

    func resume(_ item: DownloadItem) {
        guard case .paused(let data) = item.state else { return }
        guard let data else {
            restart(item)
            return
        }
        guard let webView = item.origin ?? fallbackWebView() else {
            fail(item, message: "No window available to resume in")
            return
        }
        item.state = .running
        broadcastNow()
        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            item.download = download
            item.origin = webView
            self.observe(download, for: item)
            self.broadcastNow()
        }
    }

    func retry(_ item: DownloadItem) {
        if case .failed(_, let data) = item.state, let data,
           let webView = item.origin ?? fallbackWebView() {
            item.state = .running
            broadcastNow()
            webView.resumeDownload(fromResumeData: data) { [weak self] download in
                guard let self else { return }
                download.delegate = self
                item.download = download
                item.origin = webView
                self.observe(download, for: item)
                self.broadcastNow()
            }
            return
        }
        restart(item)
    }

    // Start over from the original request, discarding any partial file.
    private func restart(_ item: DownloadItem) {
        guard let request = item.sourceRequest,
              let webView = item.origin ?? fallbackWebView() else {
            fail(item, message: "Nothing left to retry with")
            return
        }
        if let destination = item.destination {
            try? FileManager.default.removeItem(at: destination)
            item.destination = nil
        }
        item.bytesReceived = 0
        item.state = .running
        broadcastNow()
        webView.startDownload(using: request) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            item.download = download
            item.origin = webView
            self.observe(download, for: item)
            self.broadcastNow()
        }
    }

    func cancel(_ item: DownloadItem) {
        if let download = item.download {
            item.download = nil
            item.observations.removeAll()
            download.cancel(nil)
        }
        if let destination = item.destination {
            try? FileManager.default.removeItem(at: destination)
        }
        remove(item)
    }

    func remove(_ item: DownloadItem) {
        if item.state.isActive, item.download != nil {
            cancel(item)
            return
        }
        item.observations.removeAll()
        items.removeAll { $0 === item }
        broadcastNow()
    }

    func clearFinished() {
        for item in items where !item.state.isActive {
            item.observations.removeAll()
        }
        items.removeAll { !$0.state.isActive }
        broadcastNow()
    }

    func cancelAll() {
        for item in items where item.state.isActive {
            item.download?.cancel(nil)
            item.download = nil
            item.observations.removeAll()
        }
    }

    private func fail(_ item: DownloadItem, message: String) {
        item.download = nil
        item.observations.removeAll()
        item.state = .failed(message: message, resumeData: nil)
        broadcastNow()
    }

    // Any live web view will do for a resume; the originating tab may be gone.
    private func fallbackWebView() -> WKWebView? {
        for window in NSApp.windows {
            if let webView = window.contentView?.subviews.compactMap({ $0 as? WKWebView }).first {
                return webView
            }
        }
        return nil
    }

    // MARK: Change broadcast

    private func broadcastNow() {
        NotificationCenter.default.post(name: .downloadsDidChange, object: nil)
    }

    // Progress fires far faster than anyone can read. Coalesce to ~10 Hz so a
    // fast download does not thrash layout on every packet.
    private func scheduleBroadcast() {
        if broadcastScheduled { return }
        broadcastScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.broadcastScheduled = false
            self?.broadcastNow()
        }
    }

    private func announce(_ text: String) {
        NotificationCenter.default.post(name: .downloadsMessage, object: nil,
                                        userInfo: ["text": text])
    }

    // MARK: Destination

    private func sanitized(_ name: String) -> String {
        var base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        return base.isEmpty ? "download" : base
    }

    private func uniqueDestination(for name: String) -> URL {
        let fm = FileManager.default
        let directory = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let safe = sanitized(name)
        var url = directory.appendingPathComponent(safe)
        guard fm.fileExists(atPath: url.path) else { return url }

        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        var n = 1
        repeat {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            url = directory.appendingPathComponent(candidate)
            n += 1
        } while fm.fileExists(atPath: url.path) && n < 1000
        return url
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let item = item(for: download) else {
            completionHandler(nil)
            return
        }

        // A resumed download must land back on its partial file.
        if let existing = item.destination {
            completionHandler(existing)
            return
        }

        let name = [suggestedFilename, response.suggestedFilename ?? "",
                    response.url?.lastPathComponent ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "download"

        if response.expectedContentLength > 0 {
            item.bytesExpected = response.expectedContentLength
        }

        guard item.wantsSavePanel else {
            let url = uniqueDestination(for: name)
            item.destination = url
            item.filename = url.lastPathComponent
            item.state = .running
            broadcastNow()
            completionHandler(url)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitized(name)
        panel.directoryURL = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self else {
                completionHandler(nil)
                return
            }
            if result == .OK, let url = panel.url {
                item.destination = url
                item.filename = url.lastPathComponent
                item.state = .running
                self.broadcastNow()
                completionHandler(url)
            } else {
                // No row was ever shown for this one, so the toast is the only
                // feedback the user gets.
                item.download = nil
                item.observations.removeAll()
                self.items.removeAll { $0 === item }
                self.broadcastNow()
                self.announce("Download cancelled")
                completionHandler(nil)
            }
        }

        if let window = item.origin?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.observations.removeAll()
        item.download = nil
        if let url = item.destination {
            if let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64 {
                item.bytesReceived = size
                item.bytesExpected = size
            }
            item.state = .finished(url)
        } else {
            item.state = .failed(message: "Saved to an unknown location", resumeData: nil)
        }
        broadcastNow()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.observations.removeAll()
        item.download = nil
        // Report what actually went wrong. Whether the transfer can pick up
        // where it stopped is a separate question, answered by resumeData and
        // surfaced on the Retry button, not by guessing at the cause here.
        item.state = .failed(message: (error as NSError).localizedDescription,
                             resumeData: resumeData)
        broadcastNow()
    }
}

let downloadManager = DownloadManager()

// MARK: - Formatting

private let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f
}()

private func formatBytes(_ n: Int64) -> String {
    byteFormatter.string(fromByteCount: max(0, n))
}

// MARK: - Row

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class DownloadRowView: NSView, NSDraggingSource {
    static let height: CGFloat = 56

    var onPrimary: (() -> Void)?
    var onSecondary: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let track = NSView()
    private let fill = NSView()
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?
    private var showsProgress = false
    private var fileURL: URL?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.textColor = .labelColor
        addSubview(nameLabel)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)

        track.wantsLayer = true
        track.layer?.cornerRadius = 1.5
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addSubview(track)

        fill.wantsLayer = true
        fill.layer?.cornerRadius = 1.5
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        track.addSubview(fill)

        for button in [primaryButton, secondaryButton] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.contentTintColor = .secondaryLabelColor
            button.isHidden = true
            button.target = self
            addSubview(button)
        }
        primaryButton.font = .systemFont(ofSize: 11, weight: .medium)
        primaryButton.action = #selector(primaryClicked)
        secondaryButton.font = .systemFont(ofSize: 9, weight: .bold)
        secondaryButton.title = "✕"
        secondaryButton.action = #selector(secondaryClicked)

        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func primaryClicked() { onPrimary?() }
    @objc private func secondaryClicked() { onSecondary?() }

    func apply(_ item: DownloadItem) {
        nameLabel.stringValue = item.filename
        toolTip = item.destination?.path ?? item.filename
        fileURL = nil
        showsProgress = false

        switch item.state {
        case .starting:
            statusLabel.stringValue = "Starting…"
            statusLabel.textColor = .secondaryLabelColor
            showsProgress = true
            primaryButton.title = ""
            primaryButton.isEnabled = false
        case .running:
            statusLabel.stringValue = item.bytesExpected > 0
                ? "\(formatBytes(item.bytesReceived)) of \(formatBytes(item.bytesExpected))"
                : formatBytes(item.bytesReceived)
            statusLabel.textColor = .secondaryLabelColor
            showsProgress = true
            primaryButton.title = "⏸"
            primaryButton.isEnabled = true
        case .paused(let resumeData):
            // WebKit only hands back resume data when the server sent a
            // validator. Without it, pressing play throws the partial file away
            // and starts over, so say that rather than quietly losing progress.
            if resumeData == nil {
                statusLabel.stringValue = "Paused · restarts from the beginning"
                statusLabel.textColor = .systemOrange
            } else {
                statusLabel.stringValue = item.bytesExpected > 0
                    ? "Paused · \(formatBytes(item.bytesReceived)) of \(formatBytes(item.bytesExpected))"
                    : "Paused · \(formatBytes(item.bytesReceived))"
                statusLabel.textColor = .secondaryLabelColor
            }
            showsProgress = true
            primaryButton.title = "▶"
            primaryButton.isEnabled = true
        case .finished(let url):
            let exists = FileManager.default.fileExists(atPath: url.path)
            fileURL = exists ? url : nil
            statusLabel.stringValue = exists
                ? "\(formatBytes(item.bytesReceived)) · \(url.deletingLastPathComponent().lastPathComponent)"
                : "File moved or deleted"
            statusLabel.textColor = .secondaryLabelColor
            primaryButton.title = "Reveal"
            primaryButton.isEnabled = exists
        case .failed(let message, let resumeData):
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            primaryButton.title = resumeData == nil ? "Restart" : "Resume"
            primaryButton.isEnabled = true
        }

        track.isHidden = !showsProgress
        if showsProgress {
            let fraction = item.bytesExpected > 0
                ? min(1, max(0, Double(item.bytesReceived) / Double(item.bytesExpected)))
                : 0
            fill.isHidden = fraction <= 0
            fill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * CGFloat(fraction), height: 3)
        }
        needsLayout = true
    }

    private func applyStyle() {
        layer?.backgroundColor = hovering
            ? NSColor.white.withAlphaComponent(0.06).cgColor
            : NSColor.clear.cgColor
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
        primaryButton.isHidden = primaryButton.title.isEmpty
        secondaryButton.isHidden = false
        applyStyle()
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        applyStyle()
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let url = fileURL {
            NSWorkspace.shared.open(url)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let url = fileURL else { return }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        dragItem.setDraggingFrame(NSRect(x: 12, y: 12, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func layout() {
        super.layout()
        let b = bounds
        let rightEdge = b.width - 12

        secondaryButton.frame = NSRect(x: rightEdge - 18, y: 8, width: 18, height: 18)
        let primaryWidth = max(20, primaryButton.intrinsicContentSize.width + 8)
        primaryButton.frame = NSRect(x: rightEdge - 18 - 6 - primaryWidth, y: 8,
                                     width: primaryWidth, height: 18)

        let labelRight = hovering ? primaryButton.frame.minX - 8 : rightEdge
        nameLabel.frame = NSRect(x: 12, y: 8, width: max(0, labelRight - 12), height: 17)

        if showsProgress {
            track.frame = NSRect(x: 12, y: 31, width: max(0, b.width - 24), height: 3)
            let fraction = track.bounds.width > 0 ? fill.frame.width / max(1, track.frame.width) : 0
            _ = fraction
            statusLabel.frame = NSRect(x: 12, y: 37, width: max(0, b.width - 24), height: 14)
        } else {
            statusLabel.frame = NSRect(x: 12, y: 30, width: max(0, labelRight - 12), height: 14)
        }
    }
}

// MARK: - Panel

final class DownloadsPanelView: NSVisualEffectView {
    static let width: CGFloat = 380
    static let headerHeight: CGFloat = 36
    static let maxListHeight: CGFloat = 284

    var onClose: (() -> Void)?
    private(set) var pointerInside = false

    private let titleLabel = NSTextField(labelWithString: "Downloads")
    private let clearButton = NSButton()
    private let closeButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "No downloads yet")
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [UUID: DownloadRowView] = [:]
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        isHidden = true
        alphaValue = 0

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)

        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.title = "Clear"
        clearButton.font = .systemFont(ofSize: 11, weight: .medium)
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        addSubview(clearButton)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 9, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addSubview(closeButton)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        addSubview(emptyLabel)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = list
        addSubview(scroll)

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func clearClicked() { downloadManager.clearFinished() }
    @objc private func closeClicked() { onClose?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) { pointerInside = false }

    // The panel refreshes about ten times a second while a download runs, so
    // rows are reused by id. Rebuilding them would drop hover state and make
    // the action buttons flicker under the pointer.
    func refresh() {
        let items = downloadManager.items
        let live = Set(items.map { $0.id })
        for (id, row) in rows where !live.contains(id) {
            row.removeFromSuperview()
            rows.removeValue(forKey: id)
        }

        for item in items {
            let row: DownloadRowView
            if let existing = rows[item.id] {
                row = existing
            } else {
                row = DownloadRowView(frame: .zero)
                rows[item.id] = row
                list.addSubview(row)
            }
            row.onPrimary = { [weak self] in
                self?.primaryAction(for: item)
            }
            row.onSecondary = { downloadManager.remove(item) }
            row.apply(item)
        }

        emptyLabel.isHidden = !items.isEmpty
        scroll.isHidden = items.isEmpty
        clearButton.isHidden = !items.contains { !$0.state.isActive }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func primaryAction(for item: DownloadItem) {
        switch item.state {
        case .starting:
            break
        case .running:
            downloadManager.pause(item)
        case .paused:
            downloadManager.resume(item)
        case .finished(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failed:
            downloadManager.retry(item)
        }
    }

    var preferredHeight: CGFloat {
        let count = downloadManager.items.count
        let listHeight = count == 0
            ? 44
            : min(Self.maxListHeight, CGFloat(count) * DownloadRowView.height)
        return Self.headerHeight + listHeight
    }

    override func layout() {
        super.layout()
        let b = bounds
        titleLabel.frame = NSRect(x: 14, y: b.height - 24, width: 120, height: 16)
        closeButton.frame = NSRect(x: b.width - 12 - 18, y: b.height - 25, width: 18, height: 18)
        let clearWidth = max(36, clearButton.intrinsicContentSize.width + 8)
        clearButton.frame = NSRect(x: closeButton.frame.minX - 8 - clearWidth,
                                   y: b.height - 25, width: clearWidth, height: 18)

        let listHeight = b.height - Self.headerHeight
        scroll.frame = NSRect(x: 0, y: 0, width: b.width, height: listHeight)
        emptyLabel.frame = NSRect(x: 0, y: listHeight / 2 - 8, width: b.width, height: 16)

        let items = downloadManager.items
        list.frame = NSRect(x: 0, y: 0, width: b.width,
                            height: max(listHeight, CGFloat(items.count) * DownloadRowView.height))
        scroll.hasVerticalScroller = CGFloat(items.count) * DownloadRowView.height > listHeight

        for (index, item) in items.enumerated() {
            rows[item.id]?.frame = NSRect(
                x: 6, y: CGFloat(index) * DownloadRowView.height,
                width: b.width - 12, height: DownloadRowView.height)
        }
    }
}
