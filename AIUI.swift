//
// The two views the AI side needs: the sidebar that lives on the right edge of a
// browser window, and the settings window where a provider is configured.
//
// The sidebar draws whatever session the active tab hands it and owns no
// conversation state of its own — that lives on the tab, which is what makes the
// per-tab scope hold when tabs are switched, reordered, or closed.

import Cocoa

// MARK: - Markdown

// Just enough markdown for chat: fenced code, inline code, bold, italic,
// headings, bullets, links. Foundation's own markdown parser produces an
// AttributedString whose block intents still have to be turned into paragraph
// styles by hand, which is most of this work anyway — and it cannot be fed a
// half-finished stream.
enum AIMarkdown {
    // Inline spans, in the order they are tried: code, bold, bold, italic,
    // [label](url), <autolink>, bare url. The last two are here because a model
    // writes those far more often than it writes a markdown link, and the
    // transcript's own link detection is off — it would fight this string.
    private static let inlinePattern = try? NSRegularExpression(
        pattern: "`([^`]+)`|\\*\\*([^*]+)\\*\\*|__([^_]+)__|(?<![*\\w])\\*([^*\\n]+)\\*(?!\\*)"
            + "|\\[([^\\]]+)\\]\\((https?://[^)\\s]+)\\)"
            + "|<(https?://[^>\\s]+)>"
            // Must not end on punctuation: "see https://example.com." is a
            // sentence, and the full stop is not part of the address.
            + "|(?<![\\w<(])(https?://[^\\s<>)\\]]*[^\\s<>)\\]\\.,;:!?])")

    static func render(_ text: String, size: CGFloat = 12.5) -> NSAttributedString {
        let body = NSFont.systemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size - 0.5, weight: .regular)
        let out = NSMutableAttributedString()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 5

        let codeParagraph = NSMutableParagraphStyle()
        codeParagraph.lineSpacing = 1
        codeParagraph.firstLineHeadIndent = 8
        codeParagraph.headIndent = 8
        codeParagraph.paragraphSpacing = 5

        let bulletParagraph = NSMutableParagraphStyle()
        bulletParagraph.lineSpacing = 2
        bulletParagraph.paragraphSpacing = 2
        bulletParagraph.firstLineHeadIndent = 2
        bulletParagraph.headIndent = 14

        var inCode = false
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: mono,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07),
                    .paragraphStyle: codeParagraph,
                ]))
                continue
            }
            if trimmed.isEmpty {
                out.append(NSAttributedString(string: "\n", attributes: [.font: body]))
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                let heading = NSFont.systemFont(ofSize: size + (hashes <= 2 ? 1.5 : 0.5), weight: .semibold)
                let rendered = inline(title, font: heading, mono: mono)
                rendered.addAttributes([.paragraphStyle: paragraph],
                                       range: NSRange(location: 0, length: rendered.length))
                out.append(rendered)
                out.append(NSAttributedString(string: "\n"))
                continue
            }
            // Bullets and numbered items keep their marker but get a hanging
            // indent, so a wrapped line does not start under the dash.
            var content = trimmed
            var style = paragraph
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                content = "•  " + trimmed.dropFirst(2)
                style = bulletParagraph
            } else if let match = trimmed.range(of: "^\\d+\\. ", options: .regularExpression) {
                content = trimmed[match].trimmingCharacters(in: .whitespaces) + "  "
                    + trimmed[match.upperBound...]
                style = bulletParagraph
            } else if trimmed.hasPrefix("> ") {
                content = String(trimmed.dropFirst(2))
            }
            let rendered = inline(content, font: body, mono: mono)
            rendered.addAttributes([.paragraphStyle: style],
                                   range: NSRange(location: 0, length: rendered.length))
            out.append(rendered)
            out.append(NSAttributedString(string: "\n"))
        }
        return out
    }

    private static func inline(_ text: String, font: NSFont, mono: NSFont) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor,
        ]
        guard let regex = inlinePattern else {
            out.append(NSAttributedString(string: text, attributes: plain))
            return out
        }
        let full = text as NSString
        var cursor = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: full.length)) { match, _, _ in
            guard let match else { return }
            if match.range.location > cursor {
                out.append(NSAttributedString(
                    string: full.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                    attributes: plain))
            }
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : full.substring(with: range)
            }
            if let code = group(1) {
                out.append(NSAttributedString(string: code, attributes: [
                    .font: mono,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.08),
                ]))
            } else if let bold = group(2) ?? group(3) {
                out.append(NSAttributedString(string: bold, attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]))
            } else if let italic = group(4) {
                let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                out.append(NSAttributedString(string: italic, attributes: [
                    .font: italicFont, .foregroundColor: NSColor.labelColor,
                ]))
            } else if let label = group(5), let href = group(6), let url = URL(string: href) {
                out.append(link(label, url, font: font))
            } else if let href = group(7) ?? group(8), let url = URL(string: href) {
                // The address is its own label; the angle brackets, if there
                // were any, are dropped with the rest of the match.
                out.append(link(href, url, font: font))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < full.length {
            out.append(NSAttributedString(
                string: full.substring(from: cursor), attributes: plain))
        }
        return out
    }

    private static func link(_ label: String, _ url: URL, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: label, attributes: [
            .font: font,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .link: url,
        ])
    }
}

// MARK: - Composer

/// The question field. Return sends, ⇧Return and ⌥Return break the line, and Esc
/// hands the keystroke back to the sidebar — the same bargain the ⌘L HUD makes.
final class AIComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 36 || event.keyCode == 76 {
            if mods.contains(.shift) || mods.contains(.option) {
                super.keyDown(with: event)
            } else {
                onSubmit?()
            }
            return
        }
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Sidebar

final class AISidebarView: NSVisualEffectView, NSTextViewDelegate {
    static let defaultWidth: CGFloat = 380
    static let minWidth: CGFloat = 300
    static let maxWidth: CGFloat = 720
    private static let headerHeight: CGFloat = 34
    private static let contextRowHeight: CGFloat = 24
    private static let composerMinHeight: CGFloat = 34
    private static let composerMaxHeight: CGFloat = 132
    private static let grabWidth: CGFloat = 5

    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleContext: ((Bool) -> Void)?
    var onDraftChange: ((String) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    /// Live during a drag of the left edge; the controller clamps and lays out.
    var onResize: ((CGFloat) -> Void)?
    /// A model picked from the header. The controller points this tab at it.
    var onPickModel: ((AIModelRef) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "AI")
    /// The model this tab is on, and the way to change it. Its menu is every
    /// provider+model pair that passed its check, grouped by provider.
    private let modelPopup = NSPopUpButton()
    /// What the menu was built from. Rebuilding it on every delta would fight the
    /// mouse, so it is only rebuilt when the ready list actually changes.
    private var modelMenuSignature = ""
    private var modelMenuRefs: [AIModelRef] = []
    private let newChatButton = NSButton()
    private let settingsButton = NSButton()
    private let closeButton = NSButton()
    private let contextCheckbox = NSButton(checkboxWithTitle: "Use page", target: nil, action: nil)
    private let contextNote = NSTextField(labelWithString: "")
    private let transcriptScroll = NSScrollView()
    private let transcript = NSTextView()
    private let composerScroll = NSScrollView()
    private let composer = AIComposerTextView()
    private let sendButton = NSButton()
    private let placeholder = NSTextField(labelWithString: "")
    private let setupLabel = NSTextField(labelWithString: "")
    private let setupButton = NSButton()
    private var isReady = false
    private var isStreaming = false
    /// The name over an answer: the short model id this tab is on.
    private var speaker = "assistant"
    /// Which conversation was painted last, so a tab switch can swap the draft
    /// out from under the cursor — the draft belongs to the tab, not the field.
    private weak var lastSession: AIChatSession?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        isHidden = true

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)

        modelPopup.isBordered = false
        modelPopup.font = .systemFont(ofSize: 10)
        modelPopup.controlSize = .small
        modelPopup.target = self
        modelPopup.action = #selector(modelPicked)
        modelPopup.toolTip = "The model this tab is talking to"
        addSubview(modelPopup)

        for (button, glyph, tip, action) in [
            (newChatButton, "＋", "New chat in this tab", #selector(newChatClicked)),
            (settingsButton, "⚙", "AI settings", #selector(settingsClicked)),
            (closeButton, "✕", "Close the sidebar (⇧⌘A)", #selector(closeClicked)),
        ] as [(NSButton, String, String, Selector)] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.title = glyph
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = tip
            button.target = self
            button.action = action
            addSubview(button)
        }

        contextCheckbox.font = .systemFont(ofSize: 11)
        contextCheckbox.toolTip = "Send this tab's page text with the question"
        contextCheckbox.target = self
        contextCheckbox.action = #selector(contextToggled)
        addSubview(contextCheckbox)

        contextNote.font = .systemFont(ofSize: 10)
        contextNote.textColor = .tertiaryLabelColor
        contextNote.lineBreakMode = .byTruncatingMiddle
        contextNote.alignment = .right
        addSubview(contextNote)

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 12, height: 10)
        transcript.isAutomaticLinkDetectionEnabled = false
        transcript.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        transcript.delegate = self
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.documentView = transcript
        addSubview(transcriptScroll)

        placeholder.font = .systemFont(ofSize: 11.5)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 6
        placeholder.lineBreakMode = .byWordWrapping
        addSubview(placeholder)

        setupLabel.font = .systemFont(ofSize: 11.5)
        setupLabel.textColor = .secondaryLabelColor
        setupLabel.alignment = .center
        setupLabel.maximumNumberOfLines = 8
        setupLabel.lineBreakMode = .byWordWrapping
        addSubview(setupLabel)

        setupButton.title = "AI Settings…"
        setupButton.bezelStyle = .rounded
        setupButton.font = .systemFont(ofSize: 12)
        setupButton.target = self
        setupButton.action = #selector(settingsClicked)
        addSubview(setupButton)

        composer.font = .systemFont(ofSize: 12.5)
        composer.textColor = .labelColor
        composer.drawsBackground = false
        composer.isRichText = false
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.isAutomaticDashSubstitutionEnabled = false
        composer.isAutomaticTextReplacementEnabled = false
        composer.textContainerInset = NSSize(width: 4, height: 5)
        composer.delegate = self
        composer.onSubmit = { [weak self] in self?.submit() }
        composer.onEscape = { [weak self] in self?.onClose?() }
        composerScroll.drawsBackground = true
        composerScroll.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06)
        composerScroll.hasVerticalScroller = false
        composerScroll.autohidesScrollers = true
        composerScroll.wantsLayer = true
        composerScroll.layer?.cornerRadius = 9
        composerScroll.layer?.cornerCurve = .continuous
        composerScroll.documentView = composer
        addSubview(composerScroll)

        sendButton.bezelStyle = .rounded
        sendButton.font = .systemFont(ofSize: 12, weight: .medium)
        sendButton.title = "Ask"
        sendButton.keyEquivalent = ""
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        addSubview(sendButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Actions

    @objc private func modelPicked() {
        let index = modelPopup.indexOfSelectedItem
        // The last item is the way out to the settings, not a model.
        guard index >= 0, index < modelMenuRefs.count else {
            onOpenSettings?()
            return
        }
        onPickModel?(modelMenuRefs[index])
    }

    @objc private func newChatClicked() { onNewChat?() }
    @objc private func settingsClicked() { onOpenSettings?() }
    @objc private func closeClicked() { onClose?() }
    @objc private func contextToggled() { onToggleContext?(contextCheckbox.state == .on) }

    @objc private func sendClicked() {
        if isStreaming { onStop?() } else { submit() }
    }

    private func submit() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isReady, !isStreaming else { return }
        composer.string = ""
        needsLayout = true
        onSend?(text)
    }

    func focusComposer() {
        guard isReady else { return }
        window?.makeFirstResponder(composer)
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === composer else { return }
        onDraftChange?(composer.string)
        // The field grows with the question up to a point, then scrolls.
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? URL(string: (link as? String) ?? "")
        guard let url else { return false }
        onOpenLink?(url)
        return true
    }

    // MARK: Rendering

    /// Paints one session. Called on every delta while an answer streams, so it
    /// rebuilds the attributed transcript and nothing else.
    func render(session: AIChatSession, settings: AISettings) {
        let switchedTabs = lastSession !== session
        lastSession = session
        isReady = settings.isReady
        isStreaming = session.streaming
        // What this tab is actually going to talk to, which is what the header has
        // to show — not the default, and not the first thing in the list.
        let current = settings.resolve(session.model)
        speaker = current.map { AISettings.shortModel($0.model) } ?? "assistant"
        modelPopup.isHidden = !isReady
        if isReady { fillModelMenu(settings: settings, current: current) }
        contextCheckbox.state = session.includePage ? .on : .off
        contextCheckbox.isEnabled = isReady
        contextCheckbox.isHidden = !isReady
        contextNote.isHidden = !isReady
        contextNote.stringValue = session.includePage
            ? (session.pageContext?.note ?? "reading the page…")
            : "page not sent"

        setupLabel.isHidden = isReady
        setupButton.isHidden = isReady
        composerScroll.isHidden = !isReady
        sendButton.isHidden = !isReady
        transcriptScroll.isHidden = !isReady
        if !isReady {
            setupLabel.stringValue = settings.isBlank
                ? "Add a provider, paste its API key, then add the models you want. Chat unlocks once the provider's connection check passes."
                : settings.providers.contains(where: { !$0.models.isEmpty })
                    ? "No provider has passed its connection check. Run it in AI Settings and its models turn up here."
                    : "No models added yet. Add some under a provider in AI Settings."
            layoutBody()
            return
        }

        let messages = session.visibleMessages
        placeholder.isHidden = !messages.isEmpty || session.errorText != nil
        placeholder.stringValue = """
            Ask about this page.

            The tab's text goes along with the question when “Use page” is on. \
            Every tab keeps its own conversation.
            """

        let out = NSMutableAttributedString()
        for (index, message) in messages.enumerated() {
            let isUser = message.role == .user
            let header = NSAttributedString(
                string: isUser ? "You\n" : "\(speaker)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: isUser ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                ])
            out.append(header)
            // A question is shown as typed; only answers are markdown, and a
            // streaming answer stays plain until it lands so half-written
            // emphasis markers do not make the text jump.
            let streamingTail = session.streaming && index == messages.count - 1 && !isUser
            if isUser || streamingTail {
                out.append(NSAttributedString(string: message.text + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5),
                    .foregroundColor: NSColor.labelColor,
                ]))
            } else {
                out.append(AIMarkdown.render(message.text))
            }
            if let note = message.contextNote {
                out.append(NSAttributedString(string: "＋ page · \(note)\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 9.5),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 5),
            ]))
        }
        if session.streaming && session.streamingText.isEmpty {
            out.append(NSAttributedString(string: "\(speaker)\nthinking…\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        if let error = session.errorText {
            out.append(NSAttributedString(string: "⚠︎ \(error)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: NSColor.systemRed,
            ]))
        }

        // Only follow the tail when the reader is already at it; scrolling back
        // to re-read something must not be yanked away by the next delta.
        let atBottom = isScrolledToBottom
        transcript.textStorage?.setAttributedString(out)
        if atBottom || session.streaming { scrollToBottom() }

        sendButton.title = session.streaming ? "Stop" : "Ask"
        sendButton.isEnabled = true
        // Mid-typing, the field is left alone — except when the tab changed, in
        // which case what is in it belongs to the tab that just went away.
        if switchedTabs || (composer.string != session.draft && window?.firstResponder !== composer) {
            composer.string = session.draft
        }
        needsLayout = true
    }

    /// Rebuilds the picker's menu when the ready list changed, then points it at
    /// this tab's model. Providers become disabled section titles, so a long list
    /// stays readable, and the last item goes to the settings.
    private func fillModelMenu(settings: AISettings, current: AIModelRef?) {
        let refs = settings.readyModels
        let signature = refs.map { "\($0.providerID)/\($0.model)" }.joined(separator: "\n")
        let manyProviders = Set(refs.map(\.providerID)).count > 1
        // Short names that more than one provider offers.
        var counts: [String: Int] = [:]
        for ref in refs { counts[AISettings.shortModel(ref.model), default: 0] += 1 }
        let ambiguous = Set(counts.filter { $0.value > 1 }.keys)
        if signature != modelMenuSignature {
            modelMenuSignature = signature
            modelMenuRefs = refs
            let menu = NSMenu()
            var lastProvider: String?
            for ref in refs {
                guard let provider = settings.provider(ref.providerID) else { continue }
                if manyProviders, provider.id != lastProvider {
                    let title = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
                    title.isEnabled = false
                    menu.addItem(title)
                    lastProvider = provider.id
                }
                let short = AISettings.shortModel(ref.model)
                let item = NSMenuItem(title: ambiguous.contains(short) ? "\(provider.name) · \(short)" : short,
                                      action: nil, keyEquivalent: "")
                item.indentationLevel = manyProviders ? 1 : 0
                item.toolTip = "\(provider.name) · \(ref.model)"
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "Add a model…", action: nil, keyEquivalent: ""))
            modelPopup.menu = menu
        }
        guard let current, let index = modelMenuRefs.firstIndex(of: current) else { return }
        // Section titles are items too, so the row is counted, not computed.
        var row = 0
        var seen = 0
        for item in modelPopup.menu?.items ?? [] {
            if item.isEnabled, !item.isSeparatorItem {
                if seen == index { break }
                seen += 1
            }
            row += 1
        }
        modelPopup.selectItem(at: min(row, (modelPopup.menu?.items.count ?? 1) - 1))
    }

    private var isScrolledToBottom: Bool {
        let visible = transcriptScroll.contentView.documentVisibleRect
        let height = transcript.frame.height
        return visible.maxY >= height - 24
    }

    private func scrollToBottom() {
        layoutSubtreeIfNeeded()
        let height = transcript.frame.height
        let visible = transcriptScroll.contentView.bounds.height
        guard height > visible else { return }
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: height - visible))
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let b = bounds
        // The window has no titlebar of its own, so the header carries the inset
        // that keeps it clear of the rounded top corner.
        var top = b.height - 12
        top -= Self.headerHeight
        titleLabel.frame = NSRect(x: Self.grabWidth + 12, y: top + 9, width: 24, height: 16)
        let buttonSize: CGFloat = 20
        closeButton.frame = NSRect(x: b.width - 10 - buttonSize, y: top + 7, width: buttonSize, height: buttonSize)
        settingsButton.frame = NSRect(x: closeButton.frame.minX - buttonSize, y: top + 7, width: buttonSize, height: buttonSize)
        newChatButton.frame = NSRect(x: settingsButton.frame.minX - buttonSize, y: top + 7, width: buttonSize, height: buttonSize)
        let modelRoom = max(0, newChatButton.frame.minX - titleLabel.frame.maxX - 8)
        let modelTitle = modelPopup.titleOfSelectedItem ?? ""
        let titleWidth = (modelTitle as NSString)
            .size(withAttributes: [.font: modelPopup.font ?? NSFont.systemFont(ofSize: 10)]).width
        modelPopup.frame = NSRect(x: titleLabel.frame.maxX + 4, y: top + 6,
                                  width: min(titleWidth + 26, modelRoom), height: 20)
        layoutBody()
    }

    private func layoutBody() {
        let b = bounds
        let left = Self.grabWidth
        let inner = b.width - left - 12
        let headerBottom = b.height - 12 - Self.headerHeight

        guard isReady else {
            let height: CGFloat = 96
            setupLabel.frame = NSRect(x: left + 14, y: b.height / 2 - height / 2 + 30,
                                      width: inner - 16, height: height)
            setupButton.frame = NSRect(x: left + (inner - 120) / 2 + 2,
                                       y: setupLabel.frame.minY - 34, width: 120, height: 26)
            return
        }

        // The composer is measured, not guessed: its own text layout decides how
        // tall it wants to be, clamped so a pasted essay cannot eat the transcript.
        let composerWidth = inner - 56
        let textHeight: CGFloat = {
            guard let layoutManager = composer.layoutManager, let container = composer.textContainer else {
                return Self.composerMinHeight
            }
            container.containerSize = NSSize(width: composerWidth - 8, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            return layoutManager.usedRect(for: container).height + 12
        }()
        let composerHeight = min(max(textHeight, Self.composerMinHeight), Self.composerMaxHeight)

        composerScroll.frame = NSRect(x: left + 10, y: 12, width: composerWidth, height: composerHeight)
        composer.minSize = NSSize(width: 0, height: composerHeight)
        composer.textContainer?.containerSize = NSSize(width: composerWidth - 8, height: .greatestFiniteMagnitude)
        composer.textContainer?.widthTracksTextView = true
        composerScroll.hasVerticalScroller = textHeight > Self.composerMaxHeight
        sendButton.frame = NSRect(x: composerScroll.frame.maxX + 8, y: 12, width: 46, height: 26)

        let contextY = composerScroll.frame.maxY + 8
        contextCheckbox.frame = NSRect(x: left + 10, y: contextY, width: 90, height: Self.contextRowHeight)
        contextNote.frame = NSRect(x: left + 104, y: contextY + 4, width: max(0, inner - 104), height: 14)

        let transcriptTop = contextY + Self.contextRowHeight + 4
        transcriptScroll.frame = NSRect(x: left, y: transcriptTop,
                                        width: b.width - left, height: max(0, headerBottom - transcriptTop))
        transcript.minSize = NSSize(width: 0, height: transcriptScroll.frame.height)
        transcript.textContainer?.containerSize = NSSize(
            width: transcriptScroll.frame.width - 24, height: .greatestFiniteMagnitude)
        transcript.textContainer?.widthTracksTextView = true
        transcript.frame.size.width = transcriptScroll.frame.width

        placeholder.frame = NSRect(x: left + 22, y: transcriptScroll.frame.midY - 30,
                                   width: max(0, inner - 24), height: 70)
    }

    // MARK: Edge drag

    // The left edge is the handle. `hitTest` keeps the strip for the view itself
    // so a drag that starts on top of the transcript still resizes the sidebar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if local.x >= 0, local.x <= Self.grabWidth, bounds.contains(local) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(NSRect(x: 0, y: 0, width: Self.grabWidth, height: bounds.height),
                      cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.contentView?.convert(event.locationInWindow, from: nil) ?? .zero
        guard start.x - frame.minX <= Self.grabWidth else {
            super.mouseDown(with: event)
            return
        }
        let startWidth = frame.width
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp],
                           timeout: .infinity, mode: .eventTracking) { [weak self] moved, stop in
            guard let self, let moved else { stop.pointee = true; return }
            if moved.type == .leftMouseUp { stop.pointee = true; return }
            let point = window.contentView?.convert(moved.locationInWindow, from: nil) ?? .zero
            self.onResize?(startWidth + (start.x - point.x))
        }
    }
}

// MARK: - Model picker

/// The sheet behind “Load models…”: everything the endpoint says it serves, with
/// a search box and a tick next to each one. Providers that cannot list their
/// models — Anthropic — get the template's suggestions instead, and there is a
/// field for typing an id either way.
final class AIModelPickerSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let provider: AIProvider
    private let onAdd: ([String]) -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let manualField = NSTextField()
    private let addButton = NSButton()

    private var available: [AIModelInfo] = []
    private var shown: [AIModelInfo] = []
    private var picked: Set<String> = []

    init(provider: AIProvider, onAdd: @escaping ([String]) -> Void) {
        self.provider = provider
        self.onAdd = onAdd
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Add Models"
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let content = window?.contentView else { return }
        let margin: CGFloat = 16
        let inner = content.bounds.width - margin * 2
        var y = content.bounds.height - margin - 18

        titleLabel.stringValue = "Models on \(provider.name)"
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.frame = NSRect(x: margin, y: y, width: inner, height: 18)
        content.addSubview(titleLabel)

        y -= 30
        searchField.font = .systemFont(ofSize: 12)
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.frame = NSRect(x: margin, y: y, width: inner, height: 24)
        content.addSubview(searchField)

        y -= 26
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(statusLabel)

        let listBottom: CGFloat = 92
        let scroll = NSScrollView(frame: NSRect(x: margin, y: listBottom, width: inner,
                                               height: y - listBottom - 6))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table.headerView = nil
        table.rowHeight = 22
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model")))
        table.tableColumns[0].width = inner - 20
        scroll.documentView = table
        content.addSubview(scroll)

        let manualLabel = NSTextField(labelWithString: "Or type an id")
        manualLabel.font = .systemFont(ofSize: 11)
        manualLabel.textColor = .secondaryLabelColor
        manualLabel.frame = NSRect(x: margin, y: 58, width: 90, height: 16)
        content.addSubview(manualLabel)

        manualField.font = .systemFont(ofSize: 12)
        manualField.placeholderString = "claude-sonnet-4-20250514"
        manualField.frame = NSRect(x: margin + 94, y: 54, width: inner - 94, height: 22)
        content.addSubview(manualField)

        addButton.title = "Add"
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(addPicked)
        addButton.frame = NSRect(x: content.bounds.width - margin - 90, y: 14, width: 90, height: 28)
        content.addSubview(addButton)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: content.bounds.width - margin - 182, y: 14, width: 90, height: 28)
        content.addSubview(cancel)
    }

    /// Asks the endpoint for its catalogue. A provider that cannot list — or one
    /// that is not reachable yet — still gets a useful sheet: the template's
    /// suggestions, plus the field for typing an id.
    private func load() {
        let template = provider.template
        statusLabel.stringValue = template.listsModels
            ? "Asking \(provider.host) for its model list…"
            : "\(provider.name) cannot list its models — these are the known ids."
        available = template.models.map { AIModelInfo(id: $0, contextLength: 0) }
        applyFilter()
        guard template.listsModels, !provider.baseURL.isEmpty else { return }
        AIClient.models(baseURL: provider.baseURL, key: provider.apiKey) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let models):
                self.available = models
                self.statusLabel.stringValue = "\(models.count) models on \(self.provider.host)."
            case .failure(let error):
                self.statusLabel.textColor = .systemOrange
                self.statusLabel.stringValue =
                    "Could not list models — \(error.localizedDescription) Showing the known ids."
            }
            self.applyFilter()
        }
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = query.isEmpty
            ? available
            : available.filter { $0.id.lowercased().contains(query) }
        table.reloadData()
    }

    @objc private func searchChanged() { applyFilter() }

    @objc private func picked(_ sender: NSButton) {
        let id = sender.title
        if sender.state == .on { picked.insert(id) } else { picked.remove(id) }
    }

    @objc private func addPicked() {
        var ids = shown.map(\.id).filter { picked.contains($0) && !provider.models.contains($0) }
        // Anything ticked and then searched away still counts.
        ids += picked.filter { !ids.contains($0) }
        let typed = manualField.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, !ids.contains(typed) { ids.append(typed) }
        guard !ids.isEmpty else {
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "Tick a model, or type an id."
            return
        }
        onAdd(ids)
        dismiss()
    }

    @objc private func cancel() { dismiss() }

    /// `close()` is taken by NSWindowController and would tear the sheet down
    /// without telling the parent, so the sheet ends the sheet.
    private func dismiss() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let model = shown[row]
        let width = tableColumn?.width ?? 300
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        let already = provider.models.contains(model.id)
        let tick = NSButton(checkboxWithTitle: model.id, target: self, action: #selector(picked(_:)))
        tick.font = .systemFont(ofSize: 12)
        // Already on the provider: ticked, and not offered again.
        tick.state = already || picked.contains(model.id) ? .on : .off
        tick.isEnabled = !already
        tick.frame = NSRect(x: 2, y: 1, width: width - 80, height: 20)
        box.addSubview(tick)
        let trailing = already
            ? "added"
            : (model.contextLength > 0 ? "\(model.contextLength / 1000)k ctx" : "")
        if !trailing.isEmpty {
            let note = NSTextField(labelWithString: trailing)
            note.font = .systemFont(ofSize: 10)
            note.textColor = .tertiaryLabelColor
            note.alignment = .right
            note.frame = NSRect(x: width - 76, y: 3, width: 72, height: 14)
            box.addSubview(note)
        }
        return box
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

// MARK: - Settings window

/// Two lists and a form: the endpoints you have set up, the models you added
/// under the one selected, and the page-context and prompt settings that apply to
/// all of them. Nothing here picks the model for a chat — the sidebar does that,
/// per tab, from what this window collected.
final class AISettingsWindowController: NSWindowController, NSWindowDelegate,
    NSTextViewDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    static let shared = AISettingsWindowController()

    private let providersTable = NSTableView()
    private let addProviderButton = NSPopUpButton()
    private let removeProviderButton = NSButton()

    private let nameField = NSTextField()
    private let baseURLField = NSTextField()
    private let keyField = NSSecureTextField()
    private let keyLinkButton = NSButton()
    private let providerNote = NSTextField(labelWithString: "")
    private let checkButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private let modelsHeader = NSTextField(labelWithString: "MODELS")
    private let modelsTable = NSTableView()
    private let loadModelsButton = NSButton()
    private let removeModelButton = NSButton()
    private let defaultModelButton = NSButton()

    private let contextField = NSTextField()
    private let includeCheckbox = NSButton(
        checkboxWithTitle: "Send page content with new chats by default", target: nil, action: nil)
    private let promptView = NSTextView()

    /// Which row the detail form is about. Survives a reload, so a check or an
    /// edit does not move the selection.
    private var selectedProviderID: String?
    private var checking = false
    private var picker: AIModelPickerSheet?

    private var providers: [AIProvider] { aiSettingsStore.settings.providers }
    private var selected: AIProvider? { aiSettingsStore.settings.provider(selectedProviderID) }
    private var selectedModels: [String] { selected?.models ?? [] }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "AI"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        if selectedProviderID == nil { selectedProviderID = providers.first?.id }
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let width = content.bounds.width
        let margin: CGFloat = 20
        let inner = width - margin * 2
        let labelWidth: CGFloat = 74
        let fieldX = margin + labelWidth + 10
        let fieldWidth = inner - labelWidth - 10
        var y = content.bounds.height - margin

        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        func rowLabel(_ text: String, _ y: CGFloat) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.frame = NSRect(x: margin, y: y + 3, width: labelWidth, height: 16)
            content.addSubview(label)
        }

        func field(_ control: NSTextField, _ y: CGFloat, width: CGFloat, placeholder: String) {
            control.font = .systemFont(ofSize: 12)
            control.placeholderString = placeholder
            control.delegate = self
            control.frame = NSRect(x: fieldX, y: y, width: width, height: 22)
            content.addSubview(control)
        }

        func list(_ table: NSTableView, _ y: CGFloat, height: CGFloat) {
            let scroll = NSScrollView(frame: NSRect(x: margin, y: y, width: inner, height: height))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            table.headerView = nil
            table.rowHeight = 24
            table.style = .plain
            table.dataSource = self
            table.delegate = self
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
            table.tableColumns[0].width = inner - 20
            table.target = self
            scroll.documentView = table
            content.addSubview(scroll)
        }

        // Providers
        y -= 18
        let providersHeader = header("PROVIDERS")
        providersHeader.frame = NSRect(x: margin, y: y, width: 200, height: 16)
        content.addSubview(providersHeader)

        removeProviderButton.title = "Remove"
        removeProviderButton.bezelStyle = .rounded
        removeProviderButton.font = .systemFont(ofSize: 11)
        removeProviderButton.target = self
        removeProviderButton.action = #selector(removeProvider)
        removeProviderButton.frame = NSRect(x: width - margin - 78, y: y - 6, width: 78, height: 24)
        content.addSubview(removeProviderButton)

        addProviderButton.pullsDown = true
        addProviderButton.bezelStyle = .rounded
        addProviderButton.font = .systemFont(ofSize: 11)
        addProviderButton.frame = NSRect(x: removeProviderButton.frame.minX - 138, y: y - 6,
                                        width: 132, height: 24)
        let addMenu = NSMenu()
        addMenu.addItem(withTitle: "Add Provider", action: nil, keyEquivalent: "")
        for template in AIProviderTemplate.all {
            let item = NSMenuItem(title: template.name, action: #selector(addProvider(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = template.id
            addMenu.addItem(item)
        }
        addProviderButton.menu = addMenu
        content.addSubview(addProviderButton)

        y -= 96
        list(providersTable, y, height: 90)
        providersTable.action = #selector(providerRowClicked)

        // The selected provider
        y -= 30
        rowLabel("Name", y)
        field(nameField, y, width: 220, placeholder: "Google Gemini")

        keyLinkButton.title = "Get a key ↗"
        keyLinkButton.bezelStyle = .inline
        keyLinkButton.isBordered = false
        keyLinkButton.font = .systemFont(ofSize: 11)
        keyLinkButton.contentTintColor = .linkColor
        keyLinkButton.target = self
        keyLinkButton.action = #selector(openKeysPage)
        keyLinkButton.frame = NSRect(x: width - margin - 92, y: y + 2, width: 92, height: 20)
        content.addSubview(keyLinkButton)

        y -= 30
        rowLabel("Base URL", y)
        field(baseURLField, y, width: fieldWidth, placeholder: "https://host/v1")
        baseURLField.toolTip = "Everything before /chat/completions"

        y -= 30
        rowLabel("API key", y)
        field(keyField, y, width: fieldWidth, placeholder: "sk-… (leave empty for a local server)")

        y -= 20
        providerNote.font = .systemFont(ofSize: 10.5)
        providerNote.textColor = .tertiaryLabelColor
        providerNote.lineBreakMode = .byTruncatingTail
        providerNote.frame = NSRect(x: fieldX, y: y, width: fieldWidth, height: 15)
        content.addSubview(providerNote)

        y -= 32
        checkButton.title = "Check Connection"
        checkButton.bezelStyle = .rounded
        checkButton.font = .systemFont(ofSize: 12, weight: .medium)
        checkButton.keyEquivalent = "\r"
        checkButton.target = self
        checkButton.action = #selector(checkConnection)
        checkButton.frame = NSRect(x: fieldX, y: y, width: 150, height: 26)
        content.addSubview(checkButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.frame = NSRect(x: fieldX + 158, y: y - 6, width: fieldWidth - 158, height: 34)
        content.addSubview(statusLabel)

        // Models of the selected provider
        y -= 32
        modelsHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        modelsHeader.textColor = .secondaryLabelColor
        modelsHeader.frame = NSRect(x: margin, y: y, width: 300, height: 16)
        content.addSubview(modelsHeader)

        removeModelButton.title = "Remove"
        removeModelButton.bezelStyle = .rounded
        removeModelButton.font = .systemFont(ofSize: 11)
        removeModelButton.target = self
        removeModelButton.action = #selector(removeModel)
        removeModelButton.frame = NSRect(x: width - margin - 78, y: y - 6, width: 78, height: 24)
        content.addSubview(removeModelButton)

        loadModelsButton.title = "Add Models…"
        loadModelsButton.bezelStyle = .rounded
        loadModelsButton.font = .systemFont(ofSize: 11)
        loadModelsButton.target = self
        loadModelsButton.action = #selector(openModelPicker)
        loadModelsButton.frame = NSRect(x: removeModelButton.frame.minX - 138, y: y - 6,
                                       width: 132, height: 24)
        content.addSubview(loadModelsButton)

        y -= 90
        list(modelsTable, y, height: 84)
        modelsTable.doubleAction = #selector(setDefaultModel)

        y -= 30
        defaultModelButton.title = "Use for New Tabs"
        defaultModelButton.bezelStyle = .rounded
        defaultModelButton.font = .systemFont(ofSize: 11)
        defaultModelButton.target = self
        defaultModelButton.action = #selector(setDefaultModel)
        defaultModelButton.frame = NSRect(x: margin, y: y, width: 140, height: 24)
        content.addSubview(defaultModelButton)

        let modelsHint = NSTextField(labelWithString:
            "the sidebar switches between these, one choice per tab")
        modelsHint.font = .systemFont(ofSize: 10.5)
        modelsHint.textColor = .tertiaryLabelColor
        modelsHint.frame = NSRect(x: margin + 148, y: y + 4, width: inner - 148, height: 16)
        content.addSubview(modelsHint)

        // Page context
        y -= 34
        let contextHeader = header("PAGE CONTEXT")
        contextHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(contextHeader)

        y -= 28
        rowLabel("Max chars", y)
        field(contextField, y, width: 90, placeholder: "24000")
        let contextHint = NSTextField(labelWithString:
            "of page text per question — roughly four characters to a token")
        contextHint.font = .systemFont(ofSize: 10.5)
        contextHint.textColor = .tertiaryLabelColor
        contextHint.frame = NSRect(x: fieldX + 98, y: y + 3, width: inner - labelWidth - 108, height: 16)
        content.addSubview(contextHint)

        y -= 24
        includeCheckbox.font = .systemFont(ofSize: 12)
        includeCheckbox.target = self
        includeCheckbox.action = #selector(includeToggled)
        includeCheckbox.frame = NSRect(x: fieldX - 2, y: y, width: inner - labelWidth, height: 20)
        content.addSubview(includeCheckbox)

        // System prompt
        y -= 30
        let promptHeader = header("SYSTEM PROMPT")
        promptHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(promptHeader)

        y -= 96
        let promptScroll = NSScrollView(frame: NSRect(x: margin, y: y, width: inner, height: 90))
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.drawsBackground = true
        promptView.frame = NSRect(x: 0, y: 0, width: inner, height: 90)
        promptView.minSize = NSSize(width: 0, height: 90)
        promptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        promptView.isVerticallyResizable = true
        promptView.isHorizontallyResizable = false
        promptView.autoresizingMask = [.width]
        promptView.textContainer?.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        promptView.textContainer?.widthTracksTextView = true
        promptView.font = .systemFont(ofSize: 11.5)
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticTextReplacementEnabled = false
        promptView.delegate = self
        promptScroll.documentView = promptView
        content.addSubview(promptScroll)

        y -= 30
        let resetButton = NSButton(title: "Reset Prompt", target: self, action: #selector(resetPrompt))
        resetButton.bezelStyle = .rounded
        resetButton.font = .systemFont(ofSize: 11)
        resetButton.frame = NSRect(x: margin, y: y, width: 110, height: 24)
        content.addSubview(resetButton)

        let hint = NSTextField(labelWithString:
            "⇧⌘A opens the sidebar · one chat per tab · keys kept in ai.json (0600)")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: margin + 118, y: y + 4, width: inner - 118, height: 16)
        content.addSubview(hint)
    }

    // MARK: Refresh

    private func refresh() {
        let settings = aiSettingsStore.settings
        if selectedProviderID == nil || settings.provider(selectedProviderID) == nil {
            selectedProviderID = settings.providers.first?.id
        }
        providersTable.reloadData()
        if let id = selectedProviderID,
           let row = settings.providers.firstIndex(where: { $0.id == id }) {
            providersTable.selectRowIndexes([row], byExtendingSelection: false)
        }
        modelsTable.reloadData()

        let provider = selected
        let hasProvider = provider != nil
        for control in [nameField, baseURLField, keyField] as [NSTextField] {
            control.isEnabled = hasProvider
        }
        for control in [checkButton, loadModelsButton, removeModelButton,
                        defaultModelButton, removeProviderButton] {
            control.isEnabled = hasProvider
        }
        nameField.stringValue = provider?.name ?? ""
        baseURLField.stringValue = provider?.baseURL ?? ""
        keyField.stringValue = provider?.apiKey ?? ""
        // The note line doubles as the warning line: a key about to travel over
        // plain http is worth more than a reminder about what the provider is.
        if provider?.sendsKeyInClear == true {
            providerNote.textColor = .systemOrange
            providerNote.stringValue =
                "⚠︎ http:// to another machine — this key travels unencrypted. Use https, or a local server."
        } else {
            providerNote.textColor = .tertiaryLabelColor
            providerNote.stringValue = provider?.template.note ?? ""
        }
        keyLinkButton.isHidden = provider?.template.keysURL == nil
        modelsHeader.stringValue = provider.map { "MODELS ON \($0.name.uppercased())" } ?? "MODELS"

        contextField.stringValue = String(settings.maxContextCharacters)
        includeCheckbox.state = settings.includePageByDefault ? .on : .off
        if promptView.string != settings.systemPrompt { promptView.string = settings.systemPrompt }
        refreshStatus()
    }

    private func refreshStatus() {
        guard let provider = selected else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Add a provider to start."
            return
        }
        if checking {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Checking…"
            return
        }
        if provider.isVerified {
            let stamp = provider.verifiedAt.map {
                DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
            }
            statusLabel.textColor = .systemGreen
            statusLabel.stringValue = "✓ Ready"
                + (provider.verifiedLabel.map { " — \($0)" } ?? "")
                + (stamp.map { " · \($0)" } ?? "")
        } else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = provider.verifiedAt == nil
                ? "Not checked yet. Its models stay out of the sidebar until this passes."
                : "The URL or key changed. Check again to put its models back."
        }
    }

    /// Reads the form back into the selected provider and the shared settings.
    private func commitFields() {
        aiSettingsStore.update { settings in
            settings.maxContextCharacters = Int(contextField.stringValue) ?? settings.maxContextCharacters
            settings.includePageByDefault = includeCheckbox.state == .on
            settings.systemPrompt = promptView.string
            guard let id = selectedProviderID,
                  let index = settings.providers.firstIndex(where: { $0.id == id }) else { return }
            settings.providers[index].name = nameField.stringValue
            settings.providers[index].baseURL = baseURLField.stringValue
            settings.providers[index].apiKey = keyField.stringValue
        }
        refresh()
    }

    // MARK: Actions

    @objc private func addProvider(_ sender: NSMenuItem) {
        commitFields()
        let template = AIProviderTemplate.template(id: sender.representedObject as? String)
        selectedProviderID = aiSettingsStore.addProvider(template)
        refresh()
        // The key is the one thing a template cannot fill in.
        window?.makeFirstResponder(keyField)
    }

    @objc private func removeProvider() {
        guard let id = selectedProviderID else { return }
        aiSettingsStore.removeProvider(id)
        selectedProviderID = providers.first?.id
        refresh()
    }

    @objc private func providerRowClicked() {
        let row = providersTable.selectedRow
        guard row >= 0, row < providers.count else { return }
        guard providers[row].id != selectedProviderID else { return }
        selectedProviderID = providers[row].id
        refresh()
    }

    @objc private func openKeysPage() {
        guard let link = selected?.template.keysURL, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func includeToggled() { commitFields() }

    @objc private func resetPrompt() {
        promptView.string = AISettings.defaultSystemPrompt
        commitFields()
    }

    @objc private func openModelPicker() {
        commitFields()
        guard let provider = selected, let window else { return }
        let sheet = AIModelPickerSheet(provider: provider) { [weak self] ids in
            aiSettingsStore.updateProvider(provider.id) { $0.models.append(contentsOf: ids) }
            self?.refresh()
        }
        picker = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in self?.picker = nil }
    }

    @objc private func removeModel() {
        guard let provider = selected else { return }
        let row = modelsTable.selectedRow
        guard row >= 0, row < provider.models.count else { return }
        let model = provider.models[row]
        aiSettingsStore.updateProvider(provider.id) { $0.models.removeAll { $0 == model } }
        refresh()
    }

    @objc private func setDefaultModel() {
        guard let provider = selected else { return }
        let row = modelsTable.selectedRow
        guard row >= 0, row < provider.models.count else { return }
        let ref = AIModelRef(providerID: provider.id, model: provider.models[row])
        aiSettingsStore.update { $0.defaultModel = ref }
        refresh()
    }

    /// One real completion against this endpoint. The model it asks with is the
    /// first one added, or the template's first suggestion when nothing is added
    /// yet — the point is to prove the URL and the key, not the id.
    @objc private func checkConnection() {
        commitFields()
        guard let provider = selected else { return }
        guard let model = provider.models.first ?? provider.template.models.first else {
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "Add a model first — the check asks a model to answer."
            return
        }
        checking = true
        checkButton.isEnabled = false
        refreshStatus()
        AIClient.check(baseURL: provider.baseURL, key: provider.apiKey, model: model) {
            [weak self] result in
            guard let self else { return }
            self.checking = false
            self.checkButton.isEnabled = true
            switch result {
            case .success(let summary):
                aiSettingsStore.markVerified(provider.id, label: summary)
                self.refresh()
            case .failure(let error):
                self.refresh()
                self.statusLabel.textColor = .systemRed
                self.statusLabel.stringValue = "✕ \(error.localizedDescription)"
            }
        }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === providersTable ? providers.count : selectedModels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 4, y: 3, width: (tableColumn?.width ?? 300) - 8, height: 18)
        label.attributedStringValue = tableView === providersTable
            ? providerRow(providers[row])
            : modelRow(selectedModels[row])
        return label
    }

    /// `✓ Google Gemini — generativelanguage.googleapis.com · 2 models`
    private func providerRow(_ provider: AIProvider) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let verified = provider.isVerified
        out.append(NSAttributedString(string: verified ? "✓  " : "⚠  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: verified ? NSColor.systemGreen : NSColor.systemOrange,
        ]))
        out.append(NSAttributedString(string: provider.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]))
        let host = provider.baseURL.isEmpty ? "no base URL yet" : provider.host
        let count = provider.models.count
        let models = count == 1 ? "1 model" : "\(count) models"
        out.append(NSAttributedString(string: "   \(host) · \(models)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        return out
    }

    /// `gemini-2.5-flash            default for new tabs`
    private func modelRow(_ model: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: model, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])
        let isDefault = aiSettingsStore.settings.defaultModel
            == AIModelRef(providerID: selectedProviderID ?? "", model: model)
        if isDefault {
            out.append(NSAttributedString(string: "   ★ default for new tabs", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return out
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === providersTable else { return }
        providerRowClicked()
    }

    // MARK: Delegates

    func controlTextDidEndEditing(_ notification: Notification) { commitFields() }

    func textDidEndEditing(_ notification: Notification) { commitFields() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        commitFields()
        return true
    }
}
