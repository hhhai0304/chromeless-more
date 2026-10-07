import Cocoa

// MARK: - Settings window

// One window for every file-backed knob: the site-tweaks table (the JSON in
// ~/Library/Application Support/Chromeless/), the per-site zoom map, and the
// two chrome toggles that otherwise live only in menus. Edits save the moment
// they land — there is no Apply, and nothing to lose on close.
final class SettingsWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    static let shared = SettingsWindowController()

    private let aiCheckbox = NSButton(
        checkboxWithTitle: "Show AI button in the corner", target: nil, action: nil)
    private let chipCheckbox = NSButton(
        checkboxWithTitle: "Show profile name in the corner", target: nil, action: nil)
    private let primaryScreenCheckbox = NSButton(
        checkboxWithTitle: "Open new windows on the primary display", target: nil, action: nil)
    private let tweaksTable = NSTableView()
    private let zoomsTable = NSTableView()
    private let removeTweakButton = NSButton()
    private let removeZoomButton = NSButton()

    // Pattern keys that drive the table — `_`-prefixed file keys (`_readme`)
    // are docs, not sites, and never listed.
    private var patterns: [String] = []
    private var zoomEntries: [(site: String, zoom: Double)] = []

    private init() {
        // Heights below are hand-stacked the same way AdBlockUI does it; the
        // total is what the stack needs plus a bottom margin.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Settings"
        window.delegate = self
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

        func hint(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            return label
        }

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.font = .systemFont(ofSize: 12)
            return b
        }

        y -= 16
        let generalHeader = header("GENERAL")
        generalHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(generalHeader)

        y -= 26
        aiCheckbox.target = self
        aiCheckbox.action = #selector(toggleAI)
        aiCheckbox.font = .systemFont(ofSize: 13)
        aiCheckbox.frame = NSRect(x: margin + 20, y: y, width: inner - 20, height: 20)
        content.addSubview(aiCheckbox)

        y -= 24
        chipCheckbox.target = self
        chipCheckbox.action = #selector(toggleChip)
        chipCheckbox.font = .systemFont(ofSize: 13)
        chipCheckbox.frame = NSRect(x: margin + 20, y: y, width: inner - 20, height: 20)
        content.addSubview(chipCheckbox)

        y -= 24
        primaryScreenCheckbox.target = self
        primaryScreenCheckbox.action = #selector(togglePrimaryScreen)
        primaryScreenCheckbox.font = .systemFont(ofSize: 13)
        primaryScreenCheckbox.frame = NSRect(x: margin + 20, y: y, width: inner - 20, height: 20)
        content.addSubview(primaryScreenCheckbox)

        y -= 34
        let tweaksHeader = header("SITE TWEAKS — pages that behave like native apps")
        tweaksHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(tweaksHeader)

        y -= 16
        let tweaksHint = hint(
            "One '*' in a pattern matches any characters — ssh*.example.com covers " +
            "ssh-a.example.com and ssh.example.com. Exact hosts beat patterns.")
        tweaksHint.frame = NSRect(x: margin, y: y - 4, width: inner, height: 16)
        content.addSubview(tweaksHint)

        y -= 152
        let tweaksScroll = NSScrollView(frame: NSRect(x: margin, y: y, width: inner, height: 142))
        configureTweaksTable(in: tweaksScroll)
        content.addSubview(tweaksScroll)

        y -= 32
        let addTweak = button("Add…", #selector(addTweak))
        addTweak.frame = NSRect(x: margin, y: y, width: 76, height: 24)
        content.addSubview(addTweak)
        removeTweakButton.title = "Remove"
        removeTweakButton.bezelStyle = .rounded
        removeTweakButton.font = .systemFont(ofSize: 12)
        removeTweakButton.target = self
        removeTweakButton.action = #selector(removeTweak)
        removeTweakButton.frame = NSRect(x: margin + 84, y: y, width: 84, height: 24)
        content.addSubview(removeTweakButton)

        let tweaksLegend = hint(
            "App mode: page owns ⌃Tab, F12 and right-click; closing or reloading asks first. " +
            "Work: stays alive hidden. Awake: Mac never sleeps while it shows.")
        tweaksLegend.frame = NSRect(x: margin + 176, y: y - 6, width: inner - 176, height: 30)
        content.addSubview(tweaksLegend)

        y -= 44
        let zoomsHeader = header("SITE ZOOMS — remembered per site from ⌘+/⌘-")
        zoomsHeader.frame = NSRect(x: margin, y: y, width: inner, height: 16)
        content.addSubview(zoomsHeader)

        y -= 118
        let zoomsScroll = NSScrollView(frame: NSRect(x: margin, y: y, width: inner, height: 108))
        configureZoomsTable(in: zoomsScroll)
        content.addSubview(zoomsScroll)

        y -= 32
        removeZoomButton.title = "Reset to 100%"
        removeZoomButton.bezelStyle = .rounded
        removeZoomButton.font = .systemFont(ofSize: 12)
        removeZoomButton.target = self
        removeZoomButton.action = #selector(removeZoom)
        removeZoomButton.frame = NSRect(x: margin, y: y, width: 110, height: 24)
        content.addSubview(removeZoomButton)
    }

    private func configureTweaksTable(in scroll: NSScrollView) {
        tweaksTable.headerView = NSTableHeaderView()
        tweaksTable.rowHeight = 22
        tweaksTable.dataSource = self
        tweaksTable.delegate = self
        tweaksTable.selectionHighlightStyle = .regular
        tweaksTable.usesAlternatingRowBackgroundColors = true
        let widths: [(String, String, CGFloat)] = [
            ("pattern", "Pattern", 218),
            ("keepAwake", "Awake", 88),
            ("backgroundWork", "Work", 88),
            ("appMode", "App mode", 88),
            ("chromeUserAgent", "UA", 80),
        ]
        for (id, title, width) in widths {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.headerCell.stringValue = title
            column.width = width
            tweaksTable.addTableColumn(column)
        }
        scroll.documentView = tweaksTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
    }

    private func configureZoomsTable(in scroll: NSScrollView) {
        zoomsTable.headerView = NSTableHeaderView()
        zoomsTable.rowHeight = 20
        zoomsTable.dataSource = self
        zoomsTable.delegate = self
        zoomsTable.selectionHighlightStyle = .regular
        zoomsTable.usesAlternatingRowBackgroundColors = true
        let widths: [(String, String, CGFloat)] = [
            ("site", "Site", 480),
            ("zoom", "Zoom", 80),
        ]
        for (id, title, width) in widths {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.headerCell.stringValue = title
            column.width = width
            zoomsTable.addTableColumn(column)
        }
        scroll.documentView = zoomsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
    }

    // MARK: Refresh

    private func refresh() {
        aiCheckbox.state = AIButtonPreference.isOn ? .on : .off
        chipCheckbox.state = ProfileChipPreference.isOn ? .on : .off
        primaryScreenCheckbox.state = PrimaryScreenPreference.isOn ? .on : .off
        patterns = userSiteTweaks().keys.filter { !$0.hasPrefix("_") }.sorted()
        let zooms = UserDefaults.standard.dictionary(forKey: siteZoomDefaultsKey)
            as? [String: Double] ?? [:]
        zoomEntries = zooms.map { (site: $0.key, zoom: $0.value) }
            .sorted { $0.site < $1.site }
        tweaksTable.reloadData()
        zoomsTable.reloadData()
        removeTweakButton.isEnabled = tweaksTable.selectedRow >= 0
        removeZoomButton.isEnabled = zoomsTable.selectedRow >= 0
    }

    // MARK: Actions

    @objc private func toggleAI(_ sender: Any?) {
        AIButtonPreference.set(aiCheckbox.state == .on)
    }

    @objc private func toggleChip(_ sender: Any?) {
        ProfileChipPreference.set(chipCheckbox.state == .on)
    }

    @objc private func togglePrimaryScreen(_ sender: Any?) {
        PrimaryScreenPreference.set(primaryScreenCheckbox.state == .on)
    }

    @objc private func addTweak(_ sender: Any?) {
        var table = userSiteTweaks()
        var candidate = "example.com"
        for i in 2... where table[candidate] != nil { candidate = "example-\(i).com" }
        // New rows start as the usual remote-session bundle — untick what the
        // site does not need.
        table[candidate] = SiteTweaks(keepAwake: true, backgroundWork: true, appMode: true)
        saveUserSiteTweaks(table)
        refresh()
        guard let row = patterns.firstIndex(of: candidate) else { return }
        tweaksTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tweaksTable.scrollRowToVisible(row)
        tweaksTable.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeTweak(_ sender: Any?) {
        let row = tweaksTable.selectedRow
        guard patterns.indices.contains(row) else { return }
        var table = userSiteTweaks()
        table.removeValue(forKey: patterns[row])
        saveUserSiteTweaks(table)
        refresh()
    }

    @objc private func removeZoom(_ sender: Any?) {
        let row = zoomsTable.selectedRow
        guard zoomEntries.indices.contains(row) else { return }
        var zooms = UserDefaults.standard.dictionary(forKey: siteZoomDefaultsKey)
            as? [String: Double] ?? [:]
        zooms.removeValue(forKey: zoomEntries[row].site)
        UserDefaults.standard.set(zooms, forKey: siteZoomDefaultsKey)
        refresh()
    }

    @objc private func tweakFlagChanged(_ sender: NSButton) {
        let row = tweaksTable.row(for: sender)
        guard patterns.indices.contains(row),
              let flag = sender.identifier?.rawValue else { return }
        var table = userSiteTweaks()
        var tweaks = table[patterns[row]] ?? SiteTweaks()
        let on = sender.state == .on
        switch flag {
        case "keepAwake": tweaks.keepAwake = on
        case "backgroundWork": tweaks.backgroundWork = on
        case "appMode": tweaks.appMode = on
        case "chromeUserAgent": tweaks.chromeUserAgent = on
        default: return
        }
        table[patterns[row]] = tweaks
        saveUserSiteTweaks(table)
    }

    // MARK: NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === tweaksTable ? patterns.count : zoomEntries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if tableView === zoomsTable {
            guard zoomEntries.indices.contains(row), let tableColumn else { return nil }
            let entry = zoomEntries[row]
            return labelCell(tableColumn.identifier.rawValue == "site"
                ? entry.site : "\(Int((entry.zoom * 100).rounded()))%")
        }
        guard patterns.indices.contains(row), let tableColumn else { return nil }
        let key = patterns[row]
        let tweaks = userSiteTweaks()[key] ?? SiteTweaks()
        switch tableColumn.identifier.rawValue {
        case "pattern":
            let field = labelCell(key)
            field.isEditable = true
            field.delegate = self
            return field
        default:
            let on: Bool
            switch tableColumn.identifier.rawValue {
            case "keepAwake": on = tweaks.keepAwake
            case "backgroundWork": on = tweaks.backgroundWork
            case "appMode": on = tweaks.appMode
            default: on = tweaks.chromeUserAgent
            }
            let check = NSButton(checkboxWithTitle: "", target: self,
                                 action: #selector(tweakFlagChanged(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(tableColumn.identifier.rawValue)
            check.state = on ? .on : .off
            check.setButtonType(.switch)
            check.controlSize = .small
            // Checkbox cells look centered when wrapped — the table draws each
            // row's view full width, so centering happens here.
            let wrap = NSView()
            check.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(check)
            NSLayoutConstraint.activate([
                check.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                check.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            ])
            return wrap
        }
    }

    private func labelCell(_ text: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeTweakButton.isEnabled = tweaksTable.selectedRow >= 0
        removeZoomButton.isEnabled = zoomsTable.selectedRow >= 0
    }

    // MARK: NSTextFieldDelegate — pattern rename

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = tweaksTable.row(for: field)
        guard patterns.indices.contains(row) else { return }
        let old = patterns[row]
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valid = !new.isEmpty && !new.contains(" ") && !new.contains("/") && !new.contains(":")
        if valid, new != old {
            var table = userSiteTweaks()
            guard table[new] == nil, let tweaks = table[old] else {
                NSSound.beep()
                field.stringValue = old
                return
            }
            table.removeValue(forKey: old)
            table[new] = tweaks
            saveUserSiteTweaks(table)
            refresh()
        } else {
            if !valid { NSSound.beep() }
            field.stringValue = old
        }
    }
}
