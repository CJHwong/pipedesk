import AppKit
import ServiceManagement

// MARK: - Switch

// AppKit's NSSwitch always uses the system accent colour, with no public way
// to tint it. Drawing the control here keeps the green "connected" signal.
final class TunnelSwitch: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 42, height: 24) }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = track.height / 2
        let path = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        (isOn ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
        path.fill()

        let diameter = track.height - 4
        let knobX = isOn ? track.maxX - diameter - 2 : track.minX + 2
        let knob = NSRect(x: knobX, y: track.minY + 2, width: diameter, height: diameter)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn }
}

// One tunnel's controller plus the views that show it.
final class TunnelRow {
    let controller: TunnelController
    let toggleSwitch = TunnelSwitch()
    let statusLabel = NSTextField(labelWithString: "")

    init(config: TunnelConfig) {
        controller = TunnelController(config: config)
    }

    var name: String { controller.config.name }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var rows: [TunnelRow] = []
    private var pipes: [PipeController] = []
    private var setupWindow: SetupWindowController?
    private var instanceLock: Int32 = -1
    private var configError: String?
    private var pollTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireInstanceLock() else { NSApp.terminate(nil); return }
        Log.write("app launched")
        trapSignals()
        observePowerEvents()
        loadConfigAndStart(restartingAgents: true)
        loadPipes()
        if rows.isEmpty && pipes.isEmpty { showSetup() }
        // The forward becomes usable a few seconds after ssh starts, so poll
        // rather than trust the process handle alone.
        let poll = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        rows.forEach { $0.controller.stop() }
        pipes.forEach { $0.shutdown() }
    }

    // Refresh on open so no switch can show a stale position.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func loadConfigAndStart(restartingAgents: Bool = false) {
        rows.forEach { $0.controller.stop() }
        let (config, error) = Config.load()
        configError = error
        if let error { Log.write("config: \(error)") }
        rows = config.tunnels.map { TunnelRow(config: $0) }
        for row in rows {
            row.controller.onStateChange = { [weak self] in self?.refresh() }
        }
        if restartingAgents { restartAgents(from: config) }
        buildMenu()
        rows.forEach { $0.controller.start() }
    }

    // MARK: Lifecycle

    // A clean quit runs applicationWillTerminate, but a signal does not, and a
    // Cocoa app does not trap SIGTERM on its own. Without this the ssh children
    // outlive the app, still holding the forwarded ports, and nothing can reach
    // them: the menu is the only handle on those processes and it is gone.
    private func trapSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Log.write("signal \(number) received, stopping tunnels")
                self?.rows.forEach { $0.controller.stop() }
                self?.pipes.forEach { $0.stop() }
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // Several tunnels can share one pipe, so each label is restarted once.
    //
    // launchctl returns once the job is spawned, not once it is serving, so the
    // first connection attempt can still lose the race and see a refused port.
    // That is what the retry ladder is for, and one extra rung at login is not
    // worth a sleep here to paper over.
    private func restartAgents(from config: Config) {
        var labels: [String] = []
        for label in config.tunnels.compactMap(\.restartAgent) where !labels.contains(label) {
            labels.append(label)
        }
        for label in labels {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                let status = task.terminationStatus
                Log.write(status == 0
                    ? "restarted \(label)"
                    : "cannot restart \(label), launchctl exit \(status)")
            } catch {
                Log.write("cannot run launchctl for \(label): \(error.localizedDescription)")
            }
        }
    }

    private func observePowerEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Log.write("system is going to sleep")
            self?.rows.forEach { $0.controller.suspendForSleep() }
            self?.pipes.forEach { $0.suspend() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Log.write("system woke")
            self?.rows.forEach { $0.controller.resumeAfterWake() }
            self?.pipes.forEach { $0.resume() }
            self?.refresh()
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        if let configError {
            let warning = NSMenuItem(title: configError, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        addPipeMenu(to: menu)
        for (index, row) in rows.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(headerRow(for: row))
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Connect To \(row.name)"))
            for link in row.controller.config.links {
                let item = action(link.label, detail: link.detail, symbol: link.symbol,
                                  selector: #selector(openLink(_:)))
                item.representedObject = link.url
                menu.addItem(item)
            }
            if let shell = row.controller.config.shellAlias {
                let item = action("Copy Shell Command", detail: "ssh \(shell)",
                                  symbol: "terminal", selector: #selector(copyShell(_:)))
                item.representedObject = shell
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let auto = NSMenuItem(title: "Reconnect Automatically",
                              action: #selector(toggleAuto), keyEquivalent: "")
        auto.offStateImage = NSImage(size: NSSize(width: 12, height: 12))
        menu.addItem(auto)

        let login = NSMenuItem(title: "Open at Login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.offStateImage = NSImage(size: NSSize(width: 12, height: 12))
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Add Pipe or Set Up Remote...", action: #selector(showSetup), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Choose Dumbpipe Executable...", action: #selector(chooseDumbpipe), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Import SSH Configuration...", action: #selector(importSSH), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit SSH Configuration...",
                                action: #selector(editConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Reload Configuration",
                                action: #selector(reloadConfig), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, detail: String, symbol: String,
                        selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let text = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 14)])
        text.append(NSAttributedString(
            string: "   \(detail)",
            attributes: [.font: NSFont.menuFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = text
        return item
    }

    // Title row: name, live status, and the switch that drives this tunnel.
    private func headerRow(for row: TunnelRow) -> NSMenuItem {
        let width: CGFloat = 290
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 46))
        container.autoresizingMask = [.width]

        let title = NSTextField(labelWithString: "\(row.name) Tunnel")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: 14, y: 24, width: 180, height: 18)
        title.autoresizingMask = [.maxXMargin]
        container.addSubview(title)

        row.statusLabel.font = .systemFont(ofSize: 11)
        row.statusLabel.textColor = .secondaryLabelColor
        row.statusLabel.frame = NSRect(x: 14, y: 7, width: 180, height: 14)
        row.statusLabel.autoresizingMask = [.maxXMargin]
        container.addSubview(row.statusLabel)

        row.toggleSwitch.frame = NSRect(x: width - 56, y: 11, width: 42, height: 24)
        row.toggleSwitch.autoresizingMask = [.minXMargin]
        row.toggleSwitch.onToggle = { [weak self, weak row] in
            guard let row else { return }
            if row.toggleSwitch.isOn { row.controller.start() } else { row.controller.stop() }
            self?.refresh()
        }
        container.addSubview(row.toggleSwitch)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    // MARK: Refresh

    private func refresh() {
        let states = rows.map { $0.controller.state }
        for (row, state) in zip(rows, states) {
            row.controller.noteState(state)
            if state == .up { row.controller.noteHealthy() }
            row.statusLabel.stringValue = statusText(for: row, state: state)
            row.statusLabel.textColor = (state == .down && row.controller.lastError != nil)
                ? .systemRed : .secondaryLabelColor
            row.statusLabel.toolTip = row.controller.lastError
            row.toggleSwitch.isOn = row.controller.wantsConnection
        }

        let readyCount = states.filter { $0 == .up }.count + pipes.filter(\.ready).count
        let total = rows.count + pipes.count
        let active = rows.contains { $0.controller.isRunning } || pipes.contains { $0.wantsConnection }
        statusItem.button?.image = PipeIcon.image(connected: total > 0 && readyCount == total, active: active)
        let description = "PipeDesk: \(readyCount) of \(total) pipes ready"
        statusItem.button?.image?.accessibilityDescription = description
        statusItem.button?.toolTip = description
        updatePipeMenu()

        statusItem.menu?.item(withTitle: "Reconnect Automatically")?.state =
            (rows.allSatisfy { $0.controller.autoReconnect } && pipes.allSatisfy { $0.autoReconnect }) ? .on : .off
        statusItem.menu?.item(withTitle: "Open at Login")?.state =
            SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // "Disconnected" alone hides a misconfigured remote. Show ssh's own reason
    // and when the next attempt happens.
    private func statusText(for row: TunnelRow, state: TunnelState) -> String {
        if state != .down { return state.label }
        let reason = row.controller.lastError.map(shorten) ?? state.label
        if let next = row.controller.nextRetry {
            let seconds = max(0, Int(next.timeIntervalSinceNow.rounded()))
            return "\(reason)  - retry in \(seconds)s"
        }
        return reason
    }

    private func shorten(_ message: String) -> String {
        let cleaned = message
            .replacingOccurrences(of: "ssh: ", with: "")
            .replacingOccurrences(of: "Warning: ", with: "")
        return cleaned.count > 48 ? String(cleaned.prefix(48)) + "..." : cleaned
    }

    private func acquireInstanceLock() -> Bool {
        do {
            try FileManager.default.createDirectory(at: ProfileStore.standard.directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let path = ProfileStore.standard.directory.appendingPathComponent("app.lock").path
            instanceLock = open(path, O_CREAT | O_RDWR, 0o600)
            guard instanceLock >= 0 else { throw PipeError.invalid("Cannot open the application lock.") }
            guard flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else { return false }
            return true
        } catch { showError(error); return false }
    }

    private func loadPipes() {
        do {
            let profiles = try ProfileStore.standard.load()
            pipes.forEach { $0.stop() }
            pipes = profiles.map(makePipe)
            buildMenu()
        } catch { showError(error) }
    }

    private func makePipe(_ profile: PipeProfile) -> PipeController {
        let controller = PipeController(profile: profile)
        controller.onChange = { [weak self] in self?.refresh() }
        return controller
    }

    @objc private func showSetup() {
        if setupWindow == nil {
            setupWindow = SetupWindowController { [weak self] profile in
                guard let self else { return }
                try profile.validate()
                let profiles = self.pipes.map(\.profile) + [profile]
                try ProfileStore.standard.save(profiles)
                self.pipes.append(self.makePipe(profile))
                self.buildMenu()
                self.refresh()
            }
        }
        setupWindow?.showWindow(nil)
    }

    private func addPipeMenu(to menu: NSMenu) {
        for pipe in pipes {
            let parent = NSMenuItem(title: pipe.profile.name, action: nil, keyEquivalent: "")
            parent.representedObject = pipe.profile.id
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let status = NSMenuItem(title: pipe.status, action: nil, keyEquivalent: "")
            status.tag = 101
            submenu.addItem(status)
            let lastError = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            lastError.tag = 104
            lastError.isHidden = true
            submenu.addItem(lastError)
            let toggle = NSMenuItem(title: "Start", action: #selector(togglePipe(_:)), keyEquivalent: "")
            toggle.tag = 102
            toggle.representedObject = pipe.profile.id
            toggle.target = self
            submenu.addItem(toggle)
            let copy = NSMenuItem(title: pipe.profile.mode == .share ? "Copy Ticket" : "Copy Local Address",
                                  action: #selector(copyPipe(_:)), keyEquivalent: "")
            copy.tag = 103
            copy.representedObject = pipe.profile.id
            copy.target = self
            submenu.addItem(copy)
            submenu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove Profile...", action: #selector(removePipe(_:)), keyEquivalent: "")
            remove.representedObject = pipe.profile.id
            remove.target = self
            submenu.addItem(remove)
            parent.submenu = submenu
            menu.addItem(parent)
        }
        if !pipes.isEmpty { menu.addItem(.separator()) }
        if pipes.isEmpty && rows.isEmpty {
            menu.addItem(NSMenuItem(title: "No pipes yet. Add a pipe to get started.", action: nil, keyEquivalent: ""))
        }
    }

    private func updatePipeMenu() {
        for item in statusItem.menu?.items ?? [] {
            guard let identifier = item.representedObject as? UUID,
                  let pipe = pipes.first(where: { $0.profile.id == identifier }) else { continue }
            item.state = pipe.ready ? .on : .off
            item.submenu?.item(withTag: 101)?.title = pipe.status
            item.submenu?.item(withTag: 104)?.title = "Last error: \(pipe.lastError ?? "")"
            item.submenu?.item(withTag: 104)?.isHidden = pipe.lastError == nil
            item.submenu?.item(withTag: 102)?.title = pipe.wantsConnection ? "Stop" : "Start"
            item.submenu?.item(withTag: 103)?.isEnabled = pipe.profile.mode == .connect || pipe.ticket != nil
        }
    }

    private func selectedPipe(_ sender: NSMenuItem) -> PipeController? {
        guard let identifier = sender.representedObject as? UUID else { return nil }
        return pipes.first { $0.profile.id == identifier }
    }

    @objc private func togglePipe(_ sender: NSMenuItem) {
        guard let pipe = selectedPipe(sender) else { return }
        if pipe.wantsConnection { pipe.stop() } else { pipe.start() }
    }

    @objc private func copyPipe(_ sender: NSMenuItem) {
        guard let pipe = selectedPipe(sender) else { return }
        let text = pipe.profile.mode == .share ? pipe.ticket : "127.0.0.1:\(pipe.profile.port)"
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func removePipe(_ sender: NSMenuItem) {
        guard let pipe = selectedPipe(sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(pipe.profile.name)?"
        alert.informativeText = "This stops the pipe and removes its profile. Its saved identity remains available for recovery."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let remaining = pipes.filter { $0.profile.id != pipe.profile.id }
            try ProfileStore.standard.save(remaining.map(\.profile))
            pipe.stop()
            pipes = remaining
            buildMenu()
            refresh()
        } catch { showError(error) }
    }

    @objc private func chooseDumbpipe() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Dumbpipe executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            showError(PipeError.invalid("Choose an executable file."))
            return
        }
        UserDefaults.standard.set(url.path, forKey: "dumbpipeBinary")
    }

    @objc private func importSSH() {
        let panel = NSOpenPanel()
        panel.title = "Import a PipeDesk JSON configuration"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pipedesk")
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let contents = try Data(contentsOf: url)
            _ = try Config.decode(contents)
            guard !FileManager.default.fileExists(atPath: Config.path) else {
                throw PipeError.invalid("SSH profiles already exist. Use Edit SSH Configuration to merge them.")
            }
            try contents.write(to: URL(fileURLWithPath: Config.path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.path)
            loadConfigAndStart(restartingAgents: true)
            refresh()
        } catch { showError(error) }
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.path))
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "PipeDesk needs attention"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    // MARK: Actions

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("pipedesk: login item change failed: \(error)")
        }
        refresh()
    }

    @objc private func toggleAuto() {
        let turnOn = !(rows.allSatisfy { $0.controller.autoReconnect } && pipes.allSatisfy { $0.autoReconnect })
        rows.forEach { $0.controller.autoReconnect = turnOn }
        pipes.forEach { $0.autoReconnect = turnOn }
        refresh()
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyShell(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("ssh \(shellQuote(alias))", forType: .string)
    }

    @objc private func editConfig() {
        do {
            let path = URL(fileURLWithPath: Config.path)
            if !FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.createDirectory(at: ProfileStore.standard.directory,
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try Data("{\"tunnels\": []}\n".utf8).write(to: path, options: .atomic)
            }
            NSWorkspace.shared.open(path)
        } catch { showError(error) }
    }

    @objc private func reloadConfig() {
        loadConfigAndStart()
        loadPipes()
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
