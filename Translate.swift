import Cocoa
import NaturalLanguage
import WebKit

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

// MARK: - System translation overlay

/// Presents the same translation overlay WebKit shows for its context-menu
/// Translate item. That UI is `LTUITranslationViewController` from the private
/// `TranslationUIServices` framework — WebKit instantiates it directly into an
/// NSPopover, and so do we. Everything is looked up dynamically, so a system
/// where the framework or the service is missing simply reports unavailable
/// and the caller falls back to the AI pipeline.
///
/// Unlike WebKit — which only sets `text` and lets the overlay guess — the
/// target locale is pinned to Vietnamese so the pair is right every time, and
/// Vietnamese input flips the pair to translate into English.
final class SystemTranslationOverlay {
    private var popover: NSPopover?

    /// Resolved once; a missing framework or class means the feature never
    /// existed on this system and there is nothing to retry.
    private static let viewControllerClass: NSViewController.Type? = {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/TranslationUIServices.framework"),
              bundle.load(),
              let cls = NSClassFromString("LTUITranslationViewController") as? NSViewController.Type
        else { return nil }
        return cls
    }()

    /// Checked on every call — like WebKit's canHandleContextMenuTranslation —
    /// because the service can be toggled in System Settings at runtime.
    static var isAvailable: Bool {
        guard let cls = viewControllerClass else { return false }
        return (cls as AnyObject).value(forKey: "available") as? Bool ?? false
    }

    /// Anchors the overlay to the selection rect. Returns false when the
    /// service is unavailable and nothing was presented.
    @discardableResult
    func show(text: String, relativeTo rect: NSRect, of view: NSView) -> Bool {
        guard let cls = Self.viewControllerClass, Self.isAvailable else { return false }
        let controller = cls.init()
        controller.setValue(NSAttributedString(string: text), forKey: "text")
        let (source, target) = Self.languagePair(for: text)
        controller.setValue(NSLocale(localeIdentifier: source), forKey: "sourceLocale")
        controller.setValue(NSLocale(localeIdentifier: target), forKey: "targetLocale")
        if let metaClass = NSClassFromString("LTUISourceMeta") as? NSObject.Type {
            let meta = metaClass.init()
            meta.setValue(0, forKey: "origin") // LTUISourceMetaOriginUnspecified
            controller.setValue(meta, forKey: "sourceMeta")
        }
        if controller.preferredContentSize == .zero {
            controller.preferredContentSize = NSSize(width: 400, height: 400)
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.appearance = view.effectiveAppearance
        pop.animates = true
        pop.contentViewController = controller
        pop.contentSize = controller.preferredContentSize
        popover?.close()
        popover = pop
        // A keyboard trigger has no click point, so the overlay sits at the
        // selection's trailing edge — WebKit's aim == center branch — rather
        // than below it like the AI fallback bubble.
        let edge: NSRectEdge = view.userInterfaceLayoutDirection == .rightToLeft ? .minX : .maxX
        pop.show(relativeTo: rect, of: view, preferredEdge: edge)
        return true
    }

    func close() {
        popover?.close()
        popover = nil
    }

    /// What the selection most likely is, and what it should become:
    /// Vietnamese input means the reader wants English, anything else wants
    /// Vietnamese. The source must always be pinned — unset, the overlay
    /// stops at a "Choose Language" prompt on every presentation.
    ///
    /// The recognizer is trusted only when it is sure: real sentences score
    /// above 0.9, while isolated words and proper nouns produce noise like
    /// Dutch-for-"Terminator" that would pin an absurd pair. Below the
    /// threshold the fallback is English — the foreign language a Vietnamese
    /// reader overwhelmingly Shift-selects — and the overlay's own picker is
    /// still there for the rare miss. The recognizer only needs the head of
    /// the text — dominance is stable long before 500 characters.
    static func languagePair(for text: String) -> (source: String, target: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(500)))
        guard let dominant = recognizer.dominantLanguage else { return ("en_US", "vi_VN") }
        if dominant == .vietnamese { return ("vi_VN", "en_US") }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[dominant] ?? 0
        return (confidence >= 0.6 ? localeIdentifier(for: dominant.rawValue) : "en_US", "vi_VN")
    }

    /// Turns a language tag into the region-qualified form the translation
    /// service's assets are keyed on — "en" → "en_US", "zh-Hans" → "zh_CN".
    /// Bare language tags are rejected outright: the engine reports the pair
    /// as unsupported instead of normalizing them.
    private static func localeIdentifier(for languageTag: String) -> String {
        let parts = Locale.Language(identifier: languageTag).maximalIdentifier.split(separator: "-")
        guard parts.count > 1, let region = parts.last,
              (region.count == 2 && region.allSatisfy(\.isLetter)) ||
              (region.count == 3 && region.allSatisfy(\.isNumber))
        else { return languageTag }
        return "\(parts[0])_\(region.uppercased())"
    }
}

// MARK: - Translator

/// The AI pipeline behind the system overlay, used only when the overlay
/// service is missing or disabled. `onUpdate` carries the running text plus a
/// footer naming the model that produced it.
final class Translator {
    private var stream: AIStream?

    func cancel() {
        stream?.cancel()
        stream = nil
    }

    func translate(_ text: String,
                   onUpdate: @escaping (_ text: String, _ note: String) -> Void,
                   onFinish: @escaping (Error?) -> Void) {
        cancel()
        let settings = aiSettingsStore.settings
        guard let ref = settings.resolve(nil), let provider = settings.provider(ref.providerID) else {
            onFinish(AIError(message: settings.isBlank
                ? "System translation isn't available on this Mac — set up a provider in View ▸ AI Settings."
                : "System translation isn't available — check the connection in View ▸ AI Settings."))
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
