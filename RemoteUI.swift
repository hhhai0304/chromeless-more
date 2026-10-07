// The Remote Control settings window: the on/off switch for the control
// socket and, once it is on, everything a person needs to hand their AI —
// the socket path, the wire protocol, the command list, and a ready-made
// MCP config — so "let my agent drive the browser" is a paste, not a project.
// The server it toggles lives in RemoteControl.swift.

import Cocoa

final class RemoteSettingsWindowController: NSWindowController {

    static let shared = RemoteSettingsWindowController()

    private let listenCheckbox = NSButton(
        checkboxWithTitle: "Listen for commands on the control socket",
        target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let infoView = NSTextView()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Remote Control"
        window.isReleasedWhenClosed = false
        window.center()
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The chromeless source tree, when the running .app still sits inside it
    /// — which it does for anyone who builds with build.sh and never moved it.
    /// The MCP config in the info text names real paths when it can and says
    /// "from the source tree" when it cannot.
    private var toolsDir: String? {
        let dir = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("tools")
        return FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("chromelessctl.py").path) ? dir.path : nil
    }

    // MARK: The text the user's AI gets

    private func setupInfo() -> String {
        let sock = RemoteControlServer.socketPath
        let ctl = toolsDir.map { $0 + "/chromelessctl.py" } ?? "tools/chromelessctl.py"
        let mcp = toolsDir.map { $0 + "/chromeless-mcp.py" } ?? "<chromeless source tree>/tools/chromeless-mcp.py"
        return """
        Chromeless remote control — drive the browser over a unix socket.

        Socket (owner-only, 0600):
          \(sock)
        Wire: one JSON object per line in, one JSON object per line out.
        Try it:
          printf '{"cmd":"windows"}\\n' | nc -U "\(sock)"

        The rules for an agent (enforced by the app, not by politeness):
          • Every command runs inside AI tabs — tabs the socket itself opened,
            marked orange with an "AI" pill in the tab bar and an orange rail
            at the top of the page. The user's own tabs refuse commands.
          • With more than one profile, the first "open" replies
            needProfile plus the list — ask your user which one the AI
            may use, then resend with "profile". The pick holds until
            the socket is switched off.
          • AI tabs always open in the background; nothing remote ever takes
            the user's foreground or focus. The user keeps browsing normally.
          • Windows are never closed remotely; "open" creates one only when
            the AI's profile has none — front, but never key.
          • Popups (window.open) from an AI tab stay AI tabs, marked the same.

        Commands ("window"/"tab" index into the `windows` reply; URLs take
        bare domains or searches):
          {"cmd":"ping"}
          {"cmd":"windows"}                            windows + tabs, "agent" flags, AI profile
          {"cmd":"profiles"}                           profile list + the AI's bound one
          {"cmd":"open","url":"example.com"}           new AI tab, background — add
            "profile":"<id or name>" to pick the profile the AI runs under
          {"cmd":"navigate","url":"…","tab":1}         move an AI tab
          {"cmd":"eval","js":"document.title"}         JS result; promises awaited
          {"cmd":"snap","path":"/tmp/p.png"}           or {"base64":true}
          {"cmd":"logs","kind":"net","limit":50}       console/errors/fetch+XHR feed
          {"cmd":"back"|"forward"|"reload"|"stop"|"activate"|"close"}

        Ready-made client (also useful as protocol documentation):
          \(ctl)
            windows · open · nav · eval · click · type · press · wait · snap ·
            text · html · logs · back · forward · reload · stop · activate · close

        MCP server (stdio, no dependencies — gives the AI real tools):
          {"mcpServers":{"chromeless":{"command":"python3","args":["\(mcp)"]}}}

        """
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let margin: CGFloat = 20
        let inner = content.bounds.width - margin * 2
        var y = content.bounds.height - margin

        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        func hint(_ text: String, lines: Int = 2) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = lines
            return label
        }

        y -= 16
        let topHeader = header("REMOTE CONTROL")
        topHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(topHeader)

        y -= 26
        listenCheckbox.target = self
        listenCheckbox.action = #selector(toggleListen)
        listenCheckbox.font = .systemFont(ofSize: 13)
        listenCheckbox.frame = NSRect(x: margin + 20, y: y, width: inner - 20, height: 20)
        content.addSubview(listenCheckbox)

        y -= 20
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.frame = NSRect(x: margin + 20, y: y, width: inner - 20, height: 15)
        content.addSubview(statusLabel)

        y -= 34
        let warnHint = hint(
            "Anything running as you can read pages, click, and type through this "
            + "socket — that is the point. Turn it on only while you want tools in charge.")
        warnHint.frame = NSRect(x: margin + 20, y: y - 6, width: inner - 20, height: 28)
        content.addSubview(warnHint)

        y -= 40
        let infoHeader = header("HAND THIS TO YOUR AI")
        infoHeader.frame = NSRect(x: margin, y: y, width: 300, height: 16)
        content.addSubview(infoHeader)

        let copyButton = NSButton(title: "Copy Setup Info", target: self,
                                  action: #selector(copyInfo))
        copyButton.bezelStyle = .rounded
        copyButton.font = .systemFont(ofSize: 12)
        copyButton.frame = NSRect(x: margin + inner - 130, y: y - 4, width: 130, height: 24)
        content.addSubview(copyButton)

        y -= 370
        let scroll = NSScrollView(frame: NSRect(x: margin, y: y, width: inner, height: 360))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        infoView.isEditable = false
        infoView.isSelectable = true
        infoView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        infoView.textContainerInset = NSSize(width: 8, height: 8)
        infoView.string = setupInfo()
        scroll.documentView = infoView
        content.addSubview(scroll)

        y -= 26
        let bottomHint = hint(
            "The same text is on the pasteboard after Copy Setup Info — drop it "
            + "into a chat and the agent has everything it needs.")
        bottomHint.frame = NSRect(x: margin, y: y - 4, width: inner, height: 24)
        content.addSubview(bottomHint)
    }

    // MARK: State

    private func refresh() {
        // The checkbox shows whether the socket is actually listening —
        // --remote starts it without touching the saved preference.
        listenCheckbox.state = remoteControl.running ? .on : .off
        refreshStatus()
        infoView.string = setupInfo()
    }

    private func refreshStatus() {
        if remoteControl.running {
            statusLabel.stringValue = "listening on  \(RemoteControlServer.socketPath)"
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.stringValue = "off — nothing can connect"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func toggleListen(_ sender: Any?) {
        let on = listenCheckbox.state == .on
        RemoteControlPreference.set(on)
        remoteControl.setEnabled(on)
        refreshStatus()
    }

    @objc private func copyInfo(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupInfo(), forType: .string)
    }
}
