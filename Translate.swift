import Cocoa
import NaturalLanguage
import SwiftUI
import WebKit
import Translation

// MARK: - Preference

/// Whether pressing ⇧ with an active selection translates it. On by default —
/// the gesture is deliberate enough that it earns its keep — and shared by
/// every window, which is why it lives in defaults rather than on a controller.
enum TranslatePreference {
    private static let key = "ChromelessTranslateOnShift"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }
}

// MARK: - Page script

/// Press ⇧ while a selection is up and the selection is reported with the
/// rect of its first line — enough for the app to anchor a popover. Selections
/// inside inputs and textareas are invisible to `getSelection()`, so the
/// active element is checked first. `armed` keeps the dismiss listeners cheap:
/// they only post when a translation was actually requested, so ordinary
/// scrolling never crosses the bridge.
let translateTriggerScript = """
(function () {
  var armed = false;
  function post(payload) {
    try { window.webkit.messageHandlers.chromelessTranslate.postMessage(payload); } catch (e) {}
  }
  function dismiss() {
    if (!armed) return;
    armed = false;
    post({ dismiss: true });
  }
  function info() {
    var el = document.activeElement;
    if (el && (el.tagName === "TEXTAREA" ||
               (el.tagName === "INPUT" &&
                !/^(checkbox|radio|button|submit|reset|file|image|range|color|hidden)$/i.test(el.type)))) {
      var s = el.selectionStart, e = el.selectionEnd;
      if (typeof s === "number" && typeof e === "number" && e > s) {
        var t = el.value.substring(s, e);
        if (t.trim()) {
          var r = el.getBoundingClientRect();
          return { text: t, x: r.left, y: r.top, w: r.width, h: r.height };
        }
      }
      return null;
    }
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || !String(sel).trim()) return null;
    var range;
    try { range = sel.getRangeAt(0); } catch (e) { return null; }
    // The first line's rect anchors better than the bounding box: a paragraph-
    // long selection would push a whole-selection popover far from the top.
    var rects = range.getClientRects();
    var r = (rects && rects.length) ? rects[0] : range.getBoundingClientRect();
    if (!r || (!r.width && !r.height)) return null;
    return { text: String(sel), x: r.left, y: r.top, w: r.width, h: r.height };
  }
  document.addEventListener("keydown", function (e) {
    // Any other key is intent to keep working — ⌘⇧S to shoot, typing to
    // replace the selection — so the bubble gets out of the way.
    if (e.key !== "Shift") { dismiss(); return; }
    if (e.repeat || e.metaKey || e.ctrlKey || e.altKey) return;
    var i = info();
    if (!i) return;
    armed = true;
    post({ text: i.text.slice(0, 4000), x: i.x, y: i.y, w: i.w, h: i.h });
  }, true);
  document.addEventListener("scroll", dismiss, { capture: true, passive: true });
  document.addEventListener("mousedown", dismiss, true);
  document.addEventListener("selectionchange", function () {
    var s = window.getSelection();
    if (!s || s.isCollapsed || !String(s).trim()) dismiss();
  });
  window.addEventListener("resize", dismiss);
})();
"""

/// Routes the trigger script's messages to the web view they came from.
final class TranslateRouter: NSObject, WKScriptMessageHandler {
    static let shared = TranslateRouter()
    static let messageName = "chromelessTranslate"

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? BrowserWebView,
              let body = message.body as? [String: Any] else { return }
        webView.onTranslate?(body)
    }
}

// MARK: - Errors

enum TranslateError: LocalizedError {
    /// The pair isn't supported by on-device translation — the caller falls
    /// back to the configured AI provider.
    case unsupportedPair
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPair:
            return "On-device translation doesn't cover this language pair."
        case .unavailable(let message): return message
        }
    }
}

// MARK: - Apple Translation bridge

// `TranslationSession(installedSource:)` only ever uses packs already on the
// device — it cannot ask to download one. Sessions that can ask are handed out
// exclusively by SwiftUI's `.translationTask`, so an invisible hosting view is
// parked in the window to mint them. The session is then kept and reused for
// that language pair; the bridge only fires once per pair.
@available(macOS 15.0, *)
private final class TranslationBridgeModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    var onSession: ((TranslationSession) -> Void)?
}

@available(macOS 15.0, *)
private struct TranslationBridgeView: View {
    @ObservedObject var model: TranslationBridgeModel
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                model.onSession?(session)
            }
    }
}

/// A continuation that resumes at most once: the session callback and the
/// timeout race, and only the first wins.
private final class ResumeOnce<T> {
    private enum State {
        case idle, waiting(CheckedContinuation<T, Never>), done(T)
    }
    private var state = State.idle

    var value: T {
        get async {
            switch state {
            case .done(let v): return v
            case .idle:
                return await withCheckedContinuation { c in state = .waiting(c) }
            case .waiting: fatalError("awaited twice")
            }
        }
    }

    func resume(_ v: T) {
        switch state {
        case .idle: state = .done(v)
        case .waiting(let c): state = .done(v); c.resume(returning: v)
        case .done: break
        }
    }
}

@available(macOS 15.0, *)
@MainActor
final class AppleTranslator {
    private let model = TranslationBridgeModel()
    private var hosting: NSHostingView<TranslationBridgeView>?
    /// Sessions that worked, keyed `source>target` ("auto" when the source was
    /// left for the framework to detect). A bridged session keeps its download
    /// powers, so it is worth keeping around.
    private var sessions: [String: TranslationSession] = [:]
    private var waiters: [String: ResumeOnce<TranslationSession?>] = [:]
    /// Which pair the next delivered session belongs to — the task closure
    /// hands over a bare session, so the pairing has to be tracked alongside.
    private var pendingKey: String?
    private let availability = LanguageAvailability()

    func attach(to container: NSView) {
        guard hosting == nil else { return }
        model.onSession = { [weak self] session in
            Task { @MainActor in self?.adopt(session) }
        }
        // 1x1 of transparent SwiftUI: enough to count as appeared, which is
        // all `.translationTask` asks before it will run.
        let view = NSHostingView(rootView: TranslationBridgeView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(view)
        hosting = view
    }

    private func adopt(_ session: TranslationSession) {
        guard let key = pendingKey else { return }
        pendingKey = nil
        sessions[key] = session
        waiters.removeValue(forKey: key)?.resume(session)
    }

    /// Translates into Vietnamese, or into English when the text already is —
    /// that direction is the one people reach for when they Shift a sentence
    /// they can already read.
    func translate(_ text: String) async throws -> String {
        let (source, target) = Self.languagePair(for: text)
        let key = "\(source?.minimalIdentifier ?? "auto")>\(target.minimalIdentifier)"
        if let cached = sessions[key] {
            do { return try await cached.translate(text).targetText }
            catch { sessions.removeValue(forKey: key) }
        }
        if let source,
           await availability.status(from: source, to: target) == .unsupported {
            throw TranslateError.unsupportedPair
        }
        let session = try await bridgedSession(key: key, source: source, target: target)
        return try await session.translate(text).targetText
    }

    /// Gets a download-capable session out of the hidden SwiftUI view. The
    /// system shows its own approval/progress UI if a pack has to come down
    /// first; the waiter's timeout doubles as the cancellation hatch, since a
    /// dismissed prompt delivers no session at all.
    private func bridgedSession(key: String, source: Locale.Language?,
                                target: Locale.Language) async throws -> TranslationSession {
        guard hosting != nil else {
            throw TranslateError.unavailable("The translation session can't start.")
        }
        let waiter = ResumeOnce<TranslationSession?>()
        waiters[key] = waiter
        pendingKey = key
        model.configuration = TranslationSession.Configuration(source: source, target: target)
        // An identical configuration would not re-fire the task; invalidating
        // the stored copy marks it changed and makes the fire unconditional.
        DispatchQueue.main.async { [weak self] in
            self?.model.configuration?.invalidate()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            waiter.resume(nil)
        }
        guard let session = await waiter.value else {
            waiters.removeValue(forKey: key)
            if pendingKey == key { pendingKey = nil }
            throw TranslateError.unavailable("The translation session never started.")
        }
        return session
    }

    /// What the selection most likely is, and what it should become. The
    /// recognizer only needs the head of the text — dominance is stable long
    /// before 500 characters.
    static func languagePair(for text: String) -> (source: Locale.Language?, target: Locale.Language) {
        let vi = Locale.Language(identifier: "vi")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        guard let dominant = recognizer.dominantLanguage else { return (nil, vi) }
        if dominant == .vietnamese {
            return (vi, Locale.Language(identifier: "en"))
        }
        return (Locale.Language(identifier: dominant.rawValue), vi)
    }
}

// MARK: - Translator

/// One translation pipeline per window: Apple Translation first (on-device,
/// free), the configured AI provider when the pair isn't supported or the
/// session can't start. `onUpdate` carries the running text plus a footer
/// naming the engine that produced it.
final class Translator {
    private var work: Task<Void, Never>?
    private var stream: AIStream?
    /// Stored untyped because a stored property can't carry the availability
    /// annotation `AppleTranslator` needs — `apple()` does the narrow cast.
    private var appleBox: AnyObject?

    @available(macOS 15.0, *)
    @MainActor
    private func apple() -> AppleTranslator {
        if let existing = appleBox as? AppleTranslator { return existing }
        let created = AppleTranslator()
        appleBox = created
        return created
    }

    func attach(to container: NSView) {
        guard #available(macOS 15.0, *) else { return }
        Task { @MainActor in self.apple().attach(to: container) }
    }

    func cancel() {
        work?.cancel()
        work = nil
        stream?.cancel()
        stream = nil
    }

    func translate(_ text: String,
                   onUpdate: @escaping (_ text: String, _ note: String) -> Void,
                   onFinish: @escaping (Error?) -> Void) {
        cancel()
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            var appleError: Error?
            if #available(macOS 15.0, *) {
                do {
                    let result = try await self.apple().translate(text)
                    guard !Task.isCancelled else { return }
                    onUpdate(result, "On-device")
                    onFinish(nil)
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    appleError = error
                }
            }
            self.translateViaAI(text, appleError: appleError,
                                onUpdate: onUpdate, onFinish: onFinish)
        }
    }

    private func translateViaAI(_ text: String, appleError: Error?,
                                onUpdate: @escaping (String, String) -> Void,
                                onFinish: @escaping (Error?) -> Void) {
        let settings = aiSettingsStore.settings
        guard let ref = settings.resolve(nil), let provider = settings.provider(ref.providerID) else {
            onFinish(appleError ?? AIError(message: settings.isBlank
                ? "Set up a provider in View ▸ AI Settings — on-device translation can't handle this language."
                : "Check the connection in View ▸ AI Settings — on-device translation can't handle this language."))
            return
        }
        let note = "AI · \(AISettings.shortModel(ref.model))"
        let body: [String: Any] = [
            "model": ref.model,
            "messages": [
                ["role": "system", "content": """
                Translate the user's text to Vietnamese. If the text is already \
                in Vietnamese, translate it to English instead. Output only the \
                translation — no quotes, no explanations, preserve line breaks.
                """],
                ["role": "user", "content": text],
            ],
            "stream": true,
        ]
        guard let request = AIClient.request("/chat/completions", baseURL: provider.baseURL,
                                             key: provider.apiKey, method: "POST", body: body) else {
            onFinish(AIError(message: "Could not build the request for \(provider.baseURL)."))
            return
        }
        var accumulated = ""
        stream = AIStream(
            request: request,
            onDelta: { chunk in
                accumulated += chunk
                onUpdate(accumulated, note)
            },
            onFinish: onFinish)
    }
}

// MARK: - Popover

final class TranslatePopoverViewController: NSViewController {
    private static let width: CGFloat = 340
    private static let footerHeight: CGFloat = 22
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let footer = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 84))

        scrollView.frame = NSRect(x: 0, y: Self.footerHeight,
                                  width: Self.width, height: 84 - Self.footerHeight)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.frame = scrollView.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize =
            NSSize(width: Self.width, height: .greatestFiniteMagnitude)
        scrollView.documentView = textView

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.frame = NSRect(x: 10, y: 3, width: Self.width - 44, height: 14)
        footer.autoresizingMask = [.width, .maxYMargin]

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: Self.width - 24, y: 3, width: 16, height: 16)
        spinner.autoresizingMask = [.minXMargin, .maxYMargin]

        root.addSubview(scrollView)
        root.addSubview(footer)
        root.addSubview(spinner)
        view = root
        preferredContentSize = root.frame.size
    }

    func showLoading() {
        spinner.startAnimation(nil)
        setText("Translating…", color: .secondaryLabelColor)
        footer.stringValue = ""
        fit()
    }

    func setResult(_ text: String, note: String) {
        spinner.stopAnimation(nil)
        setText(text.isEmpty ? "…" : text, color: .labelColor)
        footer.stringValue = note
        fit()
    }

    func setError(_ message: String) {
        spinner.stopAnimation(nil)
        setText(message, color: .systemRed)
        footer.stringValue = ""
        fit()
    }

    private func setText(_ text: String, color: NSColor) {
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: color]))
        textView.scrollToBeginningOfDocument(nil)
    }

    /// The popover tracks the text: wide enough for a sentence, tall enough
    /// for a paragraph, scrolling past that.
    private func fit() {
        guard let container = textView.textContainer,
              let layout = textView.layoutManager else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let height = min(max(used + 16 + Self.footerHeight, 56), 320)
        preferredContentSize = NSSize(width: Self.width, height: height)
    }
}

/// A transient bubble anchored to the selection's first line — the same idea
/// as the toast and the link-hover chip, but floating because it points.
final class TranslatePopover {
    private var popover: NSPopover?
    private let content = TranslatePopoverViewController()

    /// Repositions on a second call, so pressing ⇧ again on a new selection
    /// moves the bubble instead of stacking another one.
    func show(relativeTo rect: NSRect, of view: NSView) {
        if popover == nil {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            p.contentViewController = content
            popover = p
        }
        content.showLoading()
        // .maxY, not .minY: the web view is flipped, so max-Y is the rect's
        // visually lower edge — the popover lands under the selection.
        popover?.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func update(_ text: String, note: String) { content.setResult(text, note: note) }
    func fail(_ message: String) { content.setError(message) }
    func close() { popover?.close() }
}
