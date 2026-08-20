// AdBlockUI.swift — the settings window and the element picker.
//
// The settings window is a real window rather than the NSAlert the profile
// picker uses: subscriptions, an allowlist and a rule editor are three lists to
// keep in view at once, which is one more than an alert can carry.

import Cocoa
import WebKit

// MARK: - Element picker

// Injected on demand into the active tab. It draws its own highlight, walks the
// DOM with the arrow keys, and hands the chosen selector back over a message
// handler. Only the main frame is reachable, so an ad inside an iframe cannot be
// picked — the frame itself can.
let adBlockPickerScript = #"""
(function () {
  if (window.__chromelessPicker) { window.__chromelessPicker.stop(); return; }

  var box = document.createElement('div');
  box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;' +
    'background:rgba(64,140,255,.22);border:1px solid rgba(64,140,255,.95);' +
    'border-radius:3px;transition:all .04s linear;';
  var hint = document.createElement('div');
  hint.style.cssText = 'position:fixed;z-index:2147483647;left:50%;top:16px;' +
    'transform:translateX(-50%);pointer-events:none;max-width:82vw;' +
    'background:rgba(20,20,26,.94);color:#f2f2f7;border-radius:9px;padding:9px 14px;' +
    'font:12px/1.45 -apple-system,system-ui,sans-serif;box-shadow:0 6px 24px rgba(0,0,0,.45);' +
    'white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';
  document.documentElement.appendChild(box);
  document.documentElement.appendChild(hint);

  var target = null;
  var lifted = 0;   // how many levels up from the element under the pointer
  var hovered = null;

  function stableClass(c) {
    if (!c || c.length > 40) return false;
    if (!/^[a-zA-Z][\w-]*$/.test(c)) return false;
    if (/[0-9a-f]{6,}/i.test(c)) return false;        // hashed build output
    if (/__[a-z0-9]{4,}$/i.test(c)) return false;     // css-modules suffix
    if (/^(css|sc|jsx|emotion|styles?)[-_]/i.test(c)) return false;
    return true;
  }

  function stableId(id) {
    return !!id && /^[a-zA-Z][\w-]*$/.test(id) && !/[0-9a-f]{8,}/i.test(id);
  }

  function segment(node) {
    var tag = node.tagName.toLowerCase();
    var classes = (typeof node.className === 'string' ? node.className : '')
      .split(/\s+/).filter(stableClass).slice(0, 3);
    if (classes.length) return tag + '.' + classes.join('.');
    var n = 1, sib = node;
    while ((sib = sib.previousElementSibling)) { if (sib.tagName === node.tagName) n++; }
    return tag + ':nth-of-type(' + n + ')';
  }

  function selectorFor(el) {
    if (stableId(el.id)) return '#' + el.id;
    var parts = [], node = el, depth = 0;
    while (node && node.nodeType === 1 && depth < 5) {
      var tag = node.tagName.toLowerCase();
      if (tag === 'html' || tag === 'body') break;
      if (stableId(node.id)) { parts.unshift('#' + node.id); break; }
      parts.unshift(segment(node));
      // Stop as soon as the path is specific enough to name this element alone;
      // every extra level is one more thing the site can change.
      try {
        var found = document.querySelectorAll(parts.join(' > '));
        if (found.length === 1 && found[0] === el) break;
      } catch (e) { break; }
      node = node.parentElement;
      depth++;
    }
    return parts.join(' > ');
  }

  function resolve() {
    var node = hovered;
    for (var i = 0; i < lifted && node && node.parentElement; i++) {
      if (node.parentElement.tagName === 'BODY') break;
      node = node.parentElement;
    }
    return node;
  }

  function paint() {
    target = resolve();
    if (!target) { box.style.display = 'none'; return; }
    var r = target.getBoundingClientRect();
    box.style.display = 'block';
    box.style.left = r.left + 'px';
    box.style.top = r.top + 'px';
    box.style.width = Math.max(0, r.width - 2) + 'px';
    box.style.height = Math.max(0, r.height - 2) + 'px';
    hint.textContent = selectorFor(target) + '   —   click to hide, ↑ ↓ resize, esc to cancel';
  }

  function onMove(e) {
    var node = document.elementFromPoint(e.clientX, e.clientY);
    if (!node || node === box || node === hint) return;
    if (node !== hovered) { hovered = node; lifted = 0; }
    paint();
  }

  function onClick(e) {
    e.preventDefault();
    e.stopPropagation();
    if (!target) { stop(); return; }
    var selector = selectorFor(target);
    stop();
    if (selector) {
      window.webkit.messageHandlers.chromelessPicker.postMessage(
        JSON.stringify({ selector: selector, host: location.hostname }));
    }
  }

  function onKey(e) {
    if (e.key === 'Escape') { e.preventDefault(); stop(); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); lifted++; paint(); return; }
    if (e.key === 'ArrowDown') { e.preventDefault(); if (lifted > 0) lifted--; paint(); }
  }

  function stop() {
    document.removeEventListener('mousemove', onMove, true);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('keydown', onKey, true);
    if (box.parentNode) box.parentNode.removeChild(box);
    if (hint.parentNode) hint.parentNode.removeChild(hint);
    window.__chromelessPicker = null;
  }

  document.addEventListener('mousemove', onMove, true);
  document.addEventListener('click', onClick, true);
  document.addEventListener('keydown', onKey, true);
  window.__chromelessPicker = { stop: stop };
  hint.textContent = 'Move over the element you want to hide — click to confirm, esc to cancel';
})();
"""#

// Routes by the message's own web view, so it never needs to know which window
// or profile the page belongs to — the same trick `AuxClickRouter` uses.
final class AdBlockPickerRouter: NSObject, WKScriptMessageHandler {
    static let shared = AdBlockPickerRouter()
    static let messageName = "chromelessPicker"

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let webView = message.webView as? BrowserWebView,
              let body = message.body as? String,
              let data = body.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let selector = payload["selector"], !selector.isEmpty,
              // The rule's domain comes from the page that is loaded, not from the
              // message: a rule for someone else's site is not the picker's to ask
              // for, and it is the whole prize if this handler is ever reachable.
              let host = webView.url?.host ?? payload["host"],
              let domain = registrableDomain(for: host)
        else { return }
        guard FilterCompiler.isSafeSelector(selector) else {
            webView.onPickedSelector?(nil)
            return
        }
        adBlockManager.appendCustomRule("\(domain)##\(selector)") {
            webView.onPickedSelector?(selector)
        }
    }
}

// MARK: - Settings window

final class AdBlockSettingsWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {

    static let shared = AdBlockSettingsWindowController()

    private let enabledCheckbox = NSButton(checkboxWithTitle: "Block ads and trackers", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let listTable = NSTableView()
    private let allowTable = NSTableView()
    private let rulesView = NSTextView()
    private let updateButton = NSButton()
    private let removeListButton = NSButton()
    private let removeSiteButton = NSButton()
    private let applyRulesButton = NSButton()
    private var observer: NSObjectProtocol?

    private var subscriptions: [AdBlockSubscription] { adBlockManager.settings.subscriptions }
    private var allowlist: [String] { adBlockManager.settings.allowlist }

    private init() {
        // The height is not a guess: `buildContent` stacks downwards and spends
        // exactly 662pt from the top margin, so this leaves the last row of
        // buttons a 22pt margin instead of hanging off the bottom edge.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 684),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Ad Blocking"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        buildContent()
        observer = NotificationCenter.default.addObserver(
            forName: .adBlockDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func present() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Layout

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let w = content.bounds.width
        let margin: CGFloat = 20
        let inner = w - margin * 2
        var y = content.bounds.height - margin

        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 12)
            return b
        }

        y -= 22
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(toggleEnabled)
        enabledCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        enabledCheckbox.frame = NSRect(x: margin, y: y, width: inner, height: 22)
        content.addSubview(enabledCheckbox)

        y -= 22
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: margin + 20, y: y, width: inner - 20, height: 18)
        content.addSubview(statusLabel)

        y -= 30
        let listsHeader = header("FILTER LISTS")
        listsHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(listsHeader)

        y -= 194
        let listScroll = NSScrollView(frame: NSRect(x: margin, y: y, width: inner, height: 188))
        configure(table: listTable, in: listScroll, rowHeight: 46)
        content.addSubview(listScroll)

        y -= 32
        let addList = button("Add List…", #selector(addList))
        addList.frame = NSRect(x: margin, y: y, width: 100, height: 24)
        content.addSubview(addList)
        removeListButton.title = "Remove"
        removeListButton.bezelStyle = .rounded
        removeListButton.font = .systemFont(ofSize: 12)
        removeListButton.target = self
        removeListButton.action = #selector(removeList)
        removeListButton.frame = NSRect(x: margin + 108, y: y, width: 90, height: 24)
        content.addSubview(removeListButton)
        updateButton.title = "Update Now"
        updateButton.bezelStyle = .rounded
        updateButton.font = .systemFont(ofSize: 12)
        updateButton.target = self
        updateButton.action = #selector(updateNow)
        updateButton.frame = NSRect(x: w - margin - 110, y: y, width: 110, height: 24)
        content.addSubview(updateButton)

        y -= 30
        let sitesHeader = header("SITES WITH BLOCKING OFF")
        sitesHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(sitesHeader)

        y -= 96
        let allowScroll = NSScrollView(frame: NSRect(x: margin, y: y, width: inner, height: 90))
        configure(table: allowTable, in: allowScroll, rowHeight: 20)
        content.addSubview(allowScroll)

        y -= 32
        removeSiteButton.title = "Block Ads Here Again"
        removeSiteButton.bezelStyle = .rounded
        removeSiteButton.font = .systemFont(ofSize: 12)
        removeSiteButton.target = self
        removeSiteButton.action = #selector(removeSite)
        removeSiteButton.frame = NSRect(x: margin, y: y, width: 180, height: 24)
        content.addSubview(removeSiteButton)

        y -= 30
        let rulesHeader = header("YOUR OWN RULES  —  ONE FILTER PER LINE")
        rulesHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(rulesHeader)

        y -= 122
        let rulesScroll = NSScrollView(frame: NSRect(x: margin, y: y, width: inner, height: 116))
        rulesScroll.hasVerticalScroller = true
        rulesScroll.borderType = .bezelBorder
        rulesScroll.drawsBackground = true
        rulesView.frame = NSRect(x: 0, y: 0, width: inner, height: 116)
        rulesView.minSize = NSSize(width: 0, height: 116)
        let unbounded = CGFloat.greatestFiniteMagnitude
        rulesView.maxSize = NSSize(width: unbounded, height: unbounded)
        rulesView.isVerticallyResizable = true
        rulesView.isHorizontallyResizable = false
        rulesView.autoresizingMask = [.width]
        rulesView.textContainer?.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        rulesView.textContainer?.widthTracksTextView = true
        rulesView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rulesView.isAutomaticQuoteSubstitutionEnabled = false
        rulesView.isAutomaticDashSubstitutionEnabled = false
        rulesView.isAutomaticTextReplacementEnabled = false
        rulesView.delegate = self
        rulesScroll.documentView = rulesView
        content.addSubview(rulesScroll)

        y -= 32
        applyRulesButton.title = "Apply Rules"
        applyRulesButton.bezelStyle = .rounded
        applyRulesButton.font = .systemFont(ofSize: 12)
        applyRulesButton.target = self
        applyRulesButton.action = #selector(applyRules)
        applyRulesButton.frame = NSRect(x: margin, y: y, width: 110, height: 24)
        content.addSubview(applyRulesButton)

        let hint = NSTextField(labelWithString: "⇧⌘B turns blocking off for the site you are on · ⌃⇧⌘E picks an element to hide")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: margin + 120, y: y + 3, width: inner - 120, height: 16)
        content.addSubview(hint)
    }

    private func configure(table: NSTableView, in scroll: NSScrollView, rowHeight: CGFloat) {
        table.headerView = nil
        table.rowHeight = rowHeight
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = scroll.bounds.width - 4
        table.addTableColumn(column)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
    }

    // MARK: Refresh

    private func refresh() {
        enabledCheckbox.state = adBlockManager.settings.enabled ? .on : .off
        statusLabel.stringValue = adBlockManager.statusLine
        updateButton.isEnabled = !adBlockManager.isUpdating && !adBlockManager.isBuilding
        updateButton.title = adBlockManager.isUpdating ? "Updating…" : "Update Now"
        removeListButton.isEnabled = listTable.selectedRow >= 0
        removeSiteButton.isEnabled = allowTable.selectedRow >= 0
        if rulesView.string != adBlockManager.settings.customRules,
           window?.firstResponder !== rulesView {
            rulesView.string = adBlockManager.settings.customRules
        }
        listTable.reloadData()
        allowTable.reloadData()
    }

    // MARK: Actions

    @objc private func toggleEnabled() {
        adBlockManager.setEnabled(enabledCheckbox.state == .on)
    }

    @objc private func updateNow() {
        adBlockManager.updateAll(force: true)
    }

    @objc private func applyRules() {
        adBlockManager.setCustomRules(rulesView.string)
    }

    @objc private func removeList() {
        let row = listTable.selectedRow
        guard subscriptions.indices.contains(row) else { return }
        adBlockManager.removeSubscription(id: subscriptions[row].id)
    }

    @objc private func removeSite() {
        let row = allowTable.selectedRow
        guard allowlist.indices.contains(row) else { return }
        adBlockManager.removeFromAllowlist(allowlist[row])
    }

    @objc private func toggleList(_ sender: NSButton) {
        guard subscriptions.indices.contains(sender.tag) else { return }
        adBlockManager.setSubscription(id: subscriptions[sender.tag].id, enabled: sender.state == .on)
    }

    @objc private func addList() {
        let alert = NSAlert()
        alert.messageText = "Add Filter List"
        alert.informativeText = "Paste the URL of a list in AdBlock Plus format."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 56))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 360, height: 22))
        nameField.placeholderString = "Name (optional)"
        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
        urlField.placeholderString = "https://example.com/filters.txt"
        container.addSubview(nameField)
        container.addSubview(urlField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = urlField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        adBlockManager.addSubscription(name: nameField.stringValue, url: urlField.stringValue) { error in
            guard let error else { return }
            let failure = NSAlert()
            failure.messageText = "Couldn’t Add That List"
            failure.informativeText = error
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === listTable ? subscriptions.count : allowlist.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let width = tableColumn?.width ?? 400
        if tableView === allowTable {
            guard allowlist.indices.contains(row) else { return nil }
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: 20))
            let label = NSTextField(labelWithString: allowlist[row])
            label.font = .systemFont(ofSize: 12)
            label.frame = NSRect(x: 6, y: 2, width: width - 12, height: 16)
            label.autoresizingMask = [.width]
            cell.addSubview(label)
            cell.textField = label
            return cell
        }

        guard subscriptions.indices.contains(row) else { return nil }
        let subscription = subscriptions[row]
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: width, height: 46))

        let check = NSButton(checkboxWithTitle: subscription.name, target: self, action: #selector(toggleList(_:)))
        check.state = subscription.enabled ? .on : .off
        check.tag = row
        check.font = .systemFont(ofSize: 12, weight: .medium)
        check.frame = NSRect(x: 6, y: 24, width: width - 12, height: 18)
        check.autoresizingMask = [.width]

        let detail = NSTextField(labelWithString: Self.detail(for: subscription))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = subscription.lastError == nil ? .secondaryLabelColor : .systemRed
        detail.lineBreakMode = .byTruncatingMiddle
        detail.frame = NSRect(x: 24, y: 6, width: width - 30, height: 14)
        detail.autoresizingMask = [.width]

        cell.addSubview(check)
        cell.addSubview(detail)
        cell.textField = detail
        return cell
    }

    private static func detail(for subscription: AdBlockSubscription) -> String {
        if let error = subscription.lastError { return "Update failed — \(error)" }
        guard let updatedAt = subscription.updatedAt else { return "Not downloaded yet · \(subscription.url)" }
        let count = subscription.ruleCount > 0 ? "\(subscription.ruleCount.formatted()) rules · " : ""
        return "\(count)updated \(AdBlockManager.relative(updatedAt))"
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeListButton.isEnabled = listTable.selectedRow >= 0
        removeSiteButton.isEnabled = allowTable.selectedRow >= 0
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Typing in the rule box and closing the window should not quietly throw
        // the edit away.
        if rulesView.string != adBlockManager.settings.customRules {
            adBlockManager.setCustomRules(rulesView.string)
        }
        return true
    }
}
