import AppKit
import Network
import ServiceManagement

// One place to change if the Android app moves to a fork.
let androidAppURL = URL(string: "https://github.com/walterl/patchpipe")!

// MARK: - Layout

// One grid for the whole menu, measured from the menu's left edge. AppKit
// places plain item text at 23 points and the text after an item's icon at
// 45 (measured on macOS 26). The custom tunnel rows must land on the same
// lines, and the address column, the shell commands and the switches all end
// at one right edge.
enum MenuGrid {
    static let textStart: CGFloat = 23
    static let iconStart: CGFloat = 23
    static let iconWidth: CGFloat = 16
    static let iconTextStart: CGFloat = 45
    static let rightEdge: CGFloat = 307
    // The right padding mirrors the left, so the rows that are views set the
    // menu's width and the switches and dots sit as close to the edge as the
    // labels sit to the other one.
    static let menuWidth: CGFloat = rightEdge + textStart - menuInset
    // The menu draws its own edge beyond a view's frame (measured on macOS 26).
    static let menuInset: CGFloat = 8
    static let rowHeight: CGFloat = 24
    static let labelFont = NSFont.menuFont(ofSize: 0)
    static let detailFont = NSFont.menuFont(ofSize: NSFont.systemFontSize(for: .small))
}

// MARK: - Switch

// AppKit's NSSwitch always uses the system accent colour, with no public way
// to tint it. Drawing the control here keeps the green "connected" signal.
final class TunnelSwitch: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    var onToggle: (() -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 18) }
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

// One check of one service behind a tunnel, keyed like TunnelRow.health.
struct ServiceCheck {
    let key: String
    let label: String
    let run: () -> ServiceHealth
}

// One tunnel's controller plus the views that show it.
final class TunnelRow {
    let controller: TunnelController
    let toggleSwitch = TunnelSwitch()
    let statusLabel = NSTextField(labelWithString: "")
    // The latest answer from each link's service, keyed by link URL. Empty
    // until the first check after the tunnel comes up.
    var health: [String: ServiceHealth] = [:]
    var checking = false
    var lastState: TunnelState?
    var linkRows: [(link: Link, view: MenuRowView)] = []

    init(config: TunnelConfig) {
        controller = TunnelController(config: config)
    }

    var name: String { controller.config.name }

    // The links whose service can be checked through this tunnel: a local
    // forward, or a host behind the SOCKS port. With no such link, the probe
    // port stands in, so a bare tunnel still gets a check.
    var checks: [ServiceCheck] {
        let config = controller.config
        let links = config.links.compactMap { link -> ServiceCheck? in
            if let port = link.localPort {
                return ServiceCheck(key: link.url, label: link.label) { probeLocalService(port: port) }
            }
            guard let target = config.proxiedTarget(of: link), let socks = config.socksPort else { return nil }
            return ServiceCheck(key: link.url, label: link.label) {
                probeThroughSOCKS(socksPort: socks, host: target.host, port: target.port)
            }
        }
        if !links.isEmpty { return links }
        let port = config.probePort
        return [ServiceCheck(key: "port:\(port)", label: "port \(port)") { probeLocalService(port: port) }]
    }

    var servicesChecked: Bool { checks.allSatisfy { health[$0.key] != nil } }
    var silentLinks: [String] { checks.filter { health[$0.key] == .notAnswering }.map(\.label) }
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
    private var serviceTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var configStamp: Date?
    private let pathMonitor = NWPathMonitor()
    private var pathSignature: String?
    private let pacServer = PACServer()
    // networksetup calls take a moment each, so they run off the main thread,
    // one at a time, in the order they were asked for.
    private let systemProxyQueue = DispatchQueue(label: "app.pipedesk.system-proxy")
    private let systemProxyRequests = LatestRequest()
    private var systemProxyNote: String?
    // False in a second copy that lost the instance lock. That copy must not
    // undo the system setting the running copy owns.
    private var ownsInstance = false
    private static let systemProxyKey = "systemProxyForSOCKSLinks"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireInstanceLock() else { NSApp.terminate(nil); return }
        ownsInstance = true
        Log.write("app launched")
        trapSignals()
        observePowerEvents()
        observeNetworkChanges()
        restoreSystemProxyLeftOver()
        stopOrphanedTunnels(for: Config.load().config.tunnels)
        pacServer.onFailure = { [weak self] message in
            DispatchQueue.main.async { self?.pacServerFailed(message) }
        }
        loadPipes()
        loadConfigAndStart(restartingAgents: true)
        if rows.isEmpty && pipes.isEmpty { showSetup() }
        // The forward becomes usable a few seconds after ssh starts, so poll
        // rather than trust the process handle alone. The same tick notices
        // an edited ssh.json, because a tunnel left running an alias that no
        // longer exists fails with nothing in the menu to say why.
        let poll = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pipes.forEach { $0.inspect() }
            self?.reloadConfigIfEdited()
            self?.refresh()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
        // Each check opens one connection to each service, so it runs far
        // less often than the poll.
        let services = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkServices()
        }
        RunLoop.main.add(services, forMode: .common)
        serviceTimer = services
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard ownsInstance else { return }
        rows.forEach { $0.controller.stop() }
        pipes.forEach { $0.shutdown() }
        // Browsers fall back to direct for other sites when the PAC is gone,
        // but the setting would still name a server that no longer answers.
        pacServer.stop()
        // Newer than anything queued, so queued work skips and quit waits only
        // for a networksetup call already running.
        _ = systemProxyRequests.next()
        systemProxyQueue.sync { restoreSystemProxy() }
    }

    // Refresh on open so no switch can show a stale position, and check the
    // services so the dots describe now rather than up to 30 seconds ago.
    func menuWillOpen(_ menu: NSMenu) {
        pipes.forEach { $0.inspect() }
        checkServices()
        refresh()
    }

    private func loadConfigAndStart(restartingAgents: Bool = false) {
        rows.forEach { $0.controller.stop() }
        configStamp = configModificationDate()
        let (config, error) = Config.load()
        configError = error
        if let error { Log.write("config: \(error)") }
        let retiredLabels: Set<String>
        do {
            retiredLabels = try retireDuplicateAgents(for: config.tunnels)
        } catch {
            let message = "SSH tunnels stopped: \(error.localizedDescription)"
            configError = message
            Log.write(message)
            rows = []
            buildMenu()
            return
        }
        syncSystemProxy(config.tunnels)
        rows = config.tunnels.map(makeRow)
        if restartingAgents { restartAgents(from: config, excluding: retiredLabels) }
        buildMenu()
        startTunnelsWhenPipesReady()
    }

    // MARK: System proxy

    // With the setting on and at least one proxied link, serve the PAC and
    // point every network service at it. Otherwise undo what PipeDesk changed.
    private func syncSystemProxy(_ tunnels: [TunnelConfig]) {
        let wanted = UserDefaults.standard.bool(forKey: Self.systemProxyKey) && proxiedHostCount(in: tunnels) > 0
        let request = systemProxyRequests.next()
        guard wanted else {
            pacServer.stop()
            systemProxyQueue.async { [weak self] in
                guard let self, self.systemProxyRequests.isLatest(request) else { return }
                self.restoreSystemProxy()
                DispatchQueue.main.async { self.systemProxyNote = nil; self.refresh() }
            }
            return
        }
        // The setting follows the listener: only a port PipeDesk holds may be named.
        pacServer.serve(proxyAutoConfig(for: tunnels)) { [weak self] in
            self?.systemProxyQueue.async {
                guard let self, self.systemProxyRequests.isLatest(request) else { return }
                self.applySystemProxy()
            }
        }
    }

    private func applySystemProxy() {
        var note: String?
        do {
            let skipped = try SystemProxy.standard.apply()
            if !skipped.isEmpty { note = "Skipped \(skipped.joined(separator: ", ")): uses another proxy file" }
        } catch {
            note = "System proxy not set: \(error.localizedDescription)"
            Log.write(note ?? "")
        }
        DispatchQueue.main.async { [weak self] in self?.systemProxyNote = note; self?.refresh() }
    }

    // The listener is gone, so the setting must not keep naming its port.
    // Try again later: the port may free up, or the network may come back.
    private func pacServerFailed(_ message: String) {
        systemProxyNote = message
        refresh()
        let request = systemProxyRequests.next()
        systemProxyQueue.async { [weak self] in
            guard let self, self.systemProxyRequests.isLatest(request) else { return }
            self.restoreSystemProxy()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.syncSystemProxy(self.rows.map(\.controller.config))
        }
    }

    private func restoreSystemProxy() {
        do { try SystemProxy.standard.restore() } catch {
            Log.write("system proxy not restored: \(error.localizedDescription)")
        }
    }

    // A crash skips applicationWillTerminate, so the record of what it changed
    // survives. Undo that first; the config load sets it again if wanted.
    private func restoreSystemProxyLeftOver() {
        systemProxyQueue.sync { restoreSystemProxy() }
    }

    @objc private func toggleSystemProxy() {
        let turnOn = !UserDefaults.standard.bool(forKey: Self.systemProxyKey)
        UserDefaults.standard.set(turnOn, forKey: Self.systemProxyKey)
        Log.write("system proxy for SOCKS links \(turnOn ? "on" : "off")")
        syncSystemProxy(rows.map(\.controller.config))
    }

    private func makeRow(_ config: TunnelConfig) -> TunnelRow {
        let row = TunnelRow(config: config)
        row.controller.onStateChange = { [weak self] in self?.refresh() }
        if let after = config.after {
            row.controller.dependencyUp = { [weak self] in
                self?.rows.first { $0.controller.config.name == after }?.controller.state == .up
            }
        }
        return row
    }

    private func retireDuplicateAgents(for tunnels: [TunnelConfig]) throws -> Set<String> {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let agents = try LegacyTunnelAgent.find(in: directory, aliases: Set(tunnels.map(\.tunnelAlias)))
        for agent in agents { try agent.retire() }
        return Set(agents.map(\.label))
    }

    // MARK: Config changes

    private func configModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Config.path))?[.modificationDate] as? Date
    }

    private func reloadConfigIfEdited() {
        let stamp = configModificationDate()
        guard stamp != configStamp else { return }
        configStamp = stamp
        applyEditedConfig()
    }

    // Keep every tunnel the edit did not touch, so one changed alias does not
    // drop the sessions running through the rest. A file caught half-written
    // or broken keeps the running tunnels and shows the error instead.
    private func applyEditedConfig() {
        let (config, error) = Config.load()
        if let error {
            configError = error
            Log.write("config: \(error); keeping the running tunnels")
            buildMenu()
            refresh()
            return
        }
        configError = nil
        syncSystemProxy(config.tunnels)
        let matches = matchTunnels(current: rows.map(\.controller.config), next: config.tunnels)
        let kept = Set(matches.compactMap { $0 })
        let removed = rows.indices.filter { !kept.contains($0) }.map { rows[$0] }
        let next = zip(config.tunnels, matches).map { tunnel, index in index.map { rows[$0] } ?? makeRow(tunnel) }
        let added = next.filter { row in !rows.contains { $0 === row } }
        removed.forEach { $0.controller.stop() }
        rows = next
        Log.write("config edited: kept \(kept.count), started \(added.count), stopped \(removed.count)")
        do {
            _ = try retireDuplicateAgents(for: added.map(\.controller.config))
        } catch {
            configError = "New SSH tunnels not started: \(error.localizedDescription)"
            Log.write(configError ?? "")
            added.forEach { $0.controller.stop() }
            buildMenu()
            refresh()
            return
        }
        buildMenu()
        refresh()
        // A changed tunnel often keeps its ports, and the old ssh needs a
        // moment to release them after SIGTERM. Starting at once would spend
        // the first attempt on a port conflict.
        let start = Timer(timeInterval: 1, repeats: false) { _ in
            added.forEach { $0.controller.start() }
        }
        RunLoop.main.add(start, forMode: .common)
    }

    // MARK: Service checks

    private func checkServices() {
        for row in rows where row.controller.state == .up && !row.checking {
            check(row)
        }
    }

    private func check(_ row: TunnelRow) {
        row.checking = true
        let checks = row.checks
        DispatchQueue.global(qos: .utility).async { [weak self, weak row] in
            let results = checks.map { ($0.key, $0.run()) }
            DispatchQueue.main.async {
                guard let row else { return }
                row.checking = false
                // A tunnel that dropped during the check has no services to report.
                guard row.controller.state == .up else { return }
                for (key, health) in results where row.health[key] != health {
                    Log.write("\(row.name): \(key) \(health == .answering ? "answering" : "not answering")")
                }
                row.health = Dictionary(uniqueKeysWithValues: results)
                self?.refresh()
            }
        }
    }

    // MARK: Network changes

    // A new network makes the waiting tunnels' backoff meaningless. Only
    // physical interfaces and gateways count, so a VPN or VM interface coming
    // and going does not trigger a round of retries.
    private func observeNetworkChanges() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces
                .filter { $0.type == .wifi || $0.type == .wiredEthernet }
                .map(\.name).sorted()
            let gateways = path.gateways.map { "\($0)" }.sorted()
            let usable = path.status == .satisfied
            let signature = "\(usable) \(interfaces) \(gateways)"
            DispatchQueue.main.async { self?.networkChanged(signature: signature, usable: usable) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "app.pipedesk.network"))
    }

    private func networkChanged(signature: String, usable: Bool) {
        defer { pathSignature = signature }
        guard let previous = pathSignature, previous != signature, usable else { return }
        Log.write("network changed")
        // A new interface, such as a dock's Ethernet, needs the setting too.
        syncSystemProxy(rows.map(\.controller.config))
        rows.forEach { $0.controller.retryNowIfWaiting() }
        rows.forEach { $0.health = [:] }
        checkServices()
        refresh()
    }

    // A tunnel that rides on a pipe cannot reach anything until that pipe
    // listens, and the pipe needs a few seconds to bind. Starting both at once
    // spends the first attempt of every tunnel on a refused port and puts it on
    // the backoff ladder, which now costs a minute rather than a rung. Wait for
    // the pipes to report ready instead. The deadline keeps a pipe that never
    // comes up from holding the tunnels hostage: they start anyway and fail the
    // way they always did.
    private func startTunnelsWhenPipesReady(deadline: Date? = nil) {
        let limit = deadline ?? Date().addingTimeInterval(30)
        let pending = pipes.contains { $0.wantsConnection && !$0.ready }
        guard pending, Date() < limit else {
            if pending { Log.write("pipes not ready in time, starting tunnels anyway") }
            rows.forEach { $0.controller.start() }
            return
        }
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.startTunnelsWhenPipesReady(deadline: limit)
        }
        RunLoop.main.add(timer, forMode: .common)
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
    private func restartAgents(from config: Config, excluding retiredLabels: Set<String>) {
        var labels: [String] = []
        for label in config.tunnels.compactMap(\.restartAgent)
        where !labels.contains(label) && !retiredLabels.contains(label) {
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
            // The PAC listener may not survive sleep. A live one answers at
            // once; a dead one starts again before the setting names it.
            if let self { self.syncSystemProxy(self.rows.map(\.controller.config)) }
            self?.refresh()
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let summary = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        summary.tag = 110
        menu.addItem(summary)
        menu.addItem(.separator())

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
            row.linkRows = []
            for link in row.controller.config.links {
                let view = MenuRowView(label: link.label, symbol: link.symbol, detail: link.detail,
                                       dot: linkDot(link, in: row))
                let item = viewItem(view, title: link.label, selector: #selector(openLink(_:)))
                item.representedObject = link.url
                row.linkRows.append((link, view))
                menu.addItem(item)
            }
            if let shell = row.controller.config.shellAlias {
                let view = MenuRowView(label: "Copy Shell Command", symbol: "terminal", detail: "ssh \(shell)")
                let item = viewItem(view, title: "Copy Shell Command", selector: #selector(copyShell(_:)))
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
        menu.addItem(.separator())

        // No key equivalents in this menu. A status menu reserves a column for
        // them on every row, which leaves wide empty padding on the right, and
        // they only work while the menu is already open.
        menu.addItem(NSMenuItem(title: "Add Pipe or Set Up Remote...", action: #selector(showSetup), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reload Configuration",
                                action: #selector(reloadConfig), keyEquivalent: ""))
        menu.addItem(.separator())
        addSettings(to: menu)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PipeDesk", action: #selector(quit), keyEquivalent: ""))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    // Set-once and rarely used items, under their own heading at the bottom so
    // the remotes and their links are what the eye finds first. They are not
    // a submenu: a submenu arrow makes the menu reserve an empty column on the
    // right of every row.
    private func addSettings(to menu: NSMenu) {
        menu.addItem(heading("Settings"))
        let systemProxy = NSMenuItem(title: "System Proxy for SOCKS Links",
                                     action: #selector(toggleSystemProxy), keyEquivalent: "")
        systemProxy.tag = 120
        systemProxy.offStateImage = NSImage(size: NSSize(width: 12, height: 12))
        menu.addItem(systemProxy)
        menu.addItem(note("", tag: 121))
        menu.addItem(NSMenuItem(title: "Edit SSH Configuration...", action: #selector(editConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Import SSH Configuration...", action: #selector(importSSH), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Dumbpipe Executable...", action: #selector(chooseDumbpipe), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Export for Android...", action: #selector(exportAndroid), keyEquivalent: ""))
        let patchpipe = MenuRowView(label: "Get Patchpipe for Android", symbol: nil, detail: "not made by PipeDesk")
        menu.addItem(viewItem(patchpipe, title: "Get Patchpipe for Android", selector: #selector(openAndroidApp)))
        menu.addItem(NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: ""))
    }


    // A label on the left, then grey detail and an optional status dot in one
    // right-aligned column, so the addresses and dots line up down the menu.
    // Tab stops count from where the item's text starts: after the icon for
    // items that have one, at the plain text column for the rest.
    private func columnTitle(_ label: String, detail: String, dot: NSColor? = nil,
                             textStart: CGFloat = MenuGrid.iconTextStart) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: MenuGrid.rightEdge - textStart)]
        let text = NSMutableAttributedString(
            string: label,
            attributes: [.font: MenuGrid.labelFont, .paragraphStyle: paragraph])
        text.append(NSAttributedString(
            string: "\t\(detail)",
            attributes: [.font: MenuGrid.detailFont,
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: paragraph]))
        guard let dot else { return text }
        text.append(NSAttributedString(
            string: "  ●",
            attributes: [.font: NSFont.menuFont(ofSize: 10), .foregroundColor: dot,
                         .paragraphStyle: paragraph]))
        return text
    }

    // A link's dot is green when its service answered the last check, grey
    // when it did not or has not been checked. A link to another host has no
    // dot, unless it goes through the tunnel's SOCKS port.
    private func linkDot(_ link: Link, in row: TunnelRow) -> NSColor? {
        guard link.localPort != nil || row.controller.config.proxiedTarget(of: link) != nil else { return nil }
        return row.health[link.url] == .answering ? .systemGreen : .tertiaryLabelColor
    }

    private func viewItem(_ view: MenuRowView, title: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.view = view
        return item
    }

    // Title row: name, live status, and the switch that drives this tunnel.
    private func headerRow(for row: TunnelRow) -> NSMenuItem {
        // Every frame is fixed from the left, because the grid is measured
        // from the menu's left edge and the menu may grow wider than this view.
        let height: CGFloat = 40
        let container = NSView(frame: NSRect(x: 0, y: 0, width: MenuGrid.menuWidth, height: height))
        container.autoresizingMask = [.width]
        let switchSize = row.toggleSwitch.intrinsicContentSize
        let textWidth = MenuGrid.rightEdge - switchSize.width - 8 - MenuGrid.textStart

        let title = NSTextField(labelWithString: row.name)
        title.font = .systemFont(ofSize: MenuGrid.labelFont.pointSize, weight: .semibold)
        title.frame = NSRect(x: MenuGrid.textStart, y: 20, width: textWidth, height: 16)
        container.addSubview(title)

        row.statusLabel.font = MenuGrid.detailFont
        row.statusLabel.textColor = .secondaryLabelColor
        row.statusLabel.lineBreakMode = .byTruncatingTail
        row.statusLabel.frame = NSRect(x: MenuGrid.textStart, y: 5, width: textWidth, height: 14)
        container.addSubview(row.statusLabel)

        row.toggleSwitch.frame = NSRect(x: MenuGrid.rightEdge - switchSize.width,
                                        y: (height - switchSize.height) / 2,
                                        width: switchSize.width, height: switchSize.height)
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
            noteTransition(row, to: state)
            row.statusLabel.stringValue = statusText(for: row, state: state)
            row.statusLabel.textColor = statusColor(for: row, state: state)
            row.statusLabel.toolTip = row.controller.lastError
            row.toggleSwitch.isOn = row.controller.wantsConnection
            for (link, view) in row.linkRows {
                view.dot = linkDot(link, in: row)
            }
        }

        let unhealthy = pipes.filter(\.unhealthy).count
        let readyCount = states.filter { $0 == .up }.count + pipes.filter { $0.ready && !$0.unhealthy }.count
        let total = rows.count + pipes.count
        let active = rows.contains { $0.controller.isRunning } || pipes.contains { $0.wantsConnection }
        statusItem.button?.image = PipeIcon.image(connected: total > 0 && readyCount == total, active: active)
        let summary = connectionSummary(tunnels: rows.filter { $0.controller.isRunning }.count,
                                        pipes: pipes.filter(\.isRunning).count, unhealthy: unhealthy)
        let description = "PipeDesk: \(summary). Local listeners do not prove remote health."
        statusItem.button?.image?.accessibilityDescription = description
        statusItem.button?.toolTip = description
        statusItem.menu?.item(withTag: 110)?.title = summary
        statusItem.menu?.item(withTag: 120)?.state =
            UserDefaults.standard.bool(forKey: Self.systemProxyKey) ? .on : .off
        if let proxyNote = statusItem.menu?.item(withTag: 121) {
            proxyNote.title = systemProxyNote ?? ""
            proxyNote.isHidden = systemProxyNote == nil
        }
        updatePipeMenu()

        statusItem.menu?.item(withTitle: "Reconnect Automatically")?.state =
            (rows.allSatisfy { $0.controller.autoReconnect } && pipes.allSatisfy { $0.autoReconnect }) ? .on : .off
        statusItem.menu?.item(withTitle: "Open at Login")?.state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        // Last, because a start calls refresh again.
        rows.forEach { $0.controller.startIfDependencyUp() }
    }

    // Old answers describe a tunnel that no longer exists, so they go when it
    // drops. A tunnel that just came up gets checked at once rather than wait
    // for the next 30 second round.
    private func noteTransition(_ row: TunnelRow, to state: TunnelState) {
        defer { row.lastState = state }
        guard state != row.lastState else { return }
        if state != .up { row.health = [:] }
        if state == .up, !row.checking { check(row) }
    }

    // "Disconnected" alone hides a misconfigured remote. Show ssh's own reason
    // and when the next attempt happens.
    private func statusText(for row: TunnelRow, state: TunnelState) -> String {
        let retry = row.controller.nextRetry.map { max(0, Int($0.timeIntervalSinceNow.rounded())) }
        return tunnelStatusText(wantsConnection: row.controller.wantsConnection, state: state,
                                lastError: row.controller.lastError, retryInSeconds: retry,
                                silentLinks: row.silentLinks, servicesChecked: row.servicesChecked,
                                waitingFor: row.controller.waitingFor)
    }

    private func statusColor(for row: TunnelRow, state: TunnelState) -> NSColor {
        guard row.controller.wantsConnection else { return .secondaryLabelColor }
        if state == .down && row.controller.lastError != nil { return .systemRed }
        if state == .up && !row.silentLinks.isEmpty { return .systemOrange }
        if state == .up && row.servicesChecked { return .systemGreen }
        return .secondaryLabelColor
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
            pipes.filter { $0.profile.autoStarts }.forEach { $0.start() }
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

    // Pipes sit under their own heading, apart from the SSH remotes, because a
    // pipe is a transport and not a place to open. Each pipe's row shows its
    // address and a status dot, so the submenu is only needed to act on it.
    private func addPipeMenu(to menu: NSMenu) {
        if !pipes.isEmpty { menu.addItem(heading("Dumbpipe Pipes")) }
        for pipe in pipes {
            let parent = NSMenuItem(title: pipe.profile.name, action: nil, keyEquivalent: "")
            parent.representedObject = pipe.profile.id
            parent.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                   accessibilityDescription: pipe.profile.name)
            parent.submenu = pipeSubmenu(for: pipe)
            menu.addItem(parent)
        }
        if !pipes.isEmpty { menu.addItem(.separator()) }
        if pipes.isEmpty && rows.isEmpty {
            menu.addItem(NSMenuItem(title: "No pipes yet. Add a pipe to get started.", action: nil, keyEquivalent: ""))
        }
    }

    // What the pipe does, how it is right now, then what you can do with it.
    // Information lines are disabled so they read as text, not as commands.
    private func pipeSubmenu(for pipe: PipeController) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let address = "127.0.0.1:\(pipe.profile.port)"
        let purpose = pipe.profile.mode == .connect
            ? "Forwards \(address) to the remote in its ticket"
            : "Shares \(address) with anyone who holds its ticket"
        submenu.addItem(note(purpose))
        submenu.addItem(note("", tag: 101))
        let lastError = note("", tag: 104)
        lastError.isHidden = true
        submenu.addItem(lastError)
        submenu.addItem(.separator())
        submenu.addItem(pipeCommand("Start Pipe", #selector(togglePipe(_:)), pipe, tag: 102))
        submenu.addItem(pipeCommand("Start When PipeDesk Opens", #selector(togglePipeAtLaunch(_:)), pipe, tag: 105))
        submenu.addItem(.separator())
        submenu.addItem(pipeCommand(pipe.profile.mode == .share ? "Copy Ticket" : "Copy Address \(address)",
                                    #selector(copyPipe(_:)), pipe, tag: 103))
        submenu.addItem(pipeCommand("Rename Pipe...", #selector(renamePipe(_:)), pipe))
        submenu.addItem(.separator())
        submenu.addItem(pipeCommand("Remove Pipe...", #selector(removePipe(_:)), pipe))
        return submenu
    }

    private func note(_ title: String, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.tag = tag
        return item
    }

    private func pipeCommand(_ title: String, _ selector: Selector, _ pipe: PipeController,
                             tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.representedObject = pipe.profile.id
        item.target = self
        item.tag = tag
        return item
    }

    private func heading(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        return note(title)
    }

    private func pipeDot(_ pipe: PipeController) -> NSColor {
        if pipe.ready { return pipe.unhealthy ? .systemOrange : .systemGreen }
        if pipe.wantsConnection && pipe.lastError != nil { return .systemRed }
        return .tertiaryLabelColor
    }

    private func updatePipeMenu() {
        for item in statusItem.menu?.items ?? [] {
            guard let identifier = item.representedObject as? UUID,
                  let pipe = pipes.first(where: { $0.profile.id == identifier }) else { continue }
            let detail = pipe.profile.mode == .share ? "sharing port \(pipe.profile.port)"
                                                     : "127.0.0.1:\(pipe.profile.port)"
            item.attributedTitle = columnTitle(pipe.profile.name, detail: detail, dot: pipeDot(pipe))
            item.submenu?.item(withTag: 101)?.title = "Status: \(pipe.status)"
            item.submenu?.item(withTag: 104)?.title = "Last error: \(pipe.lastError ?? "")"
            item.submenu?.item(withTag: 104)?.isHidden = pipe.lastError == nil
            item.submenu?.item(withTag: 102)?.title = pipe.wantsConnection ? "Stop Pipe" : "Start Pipe"
            item.submenu?.item(withTag: 103)?.isEnabled = pipe.profile.mode == .connect || pipe.ticket != nil
            item.submenu?.item(withTag: 105)?.state = pipe.profile.autoStarts ? .on : .off
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

    @objc private func togglePipeAtLaunch(_ sender: NSMenuItem) {
        guard let pipe = selectedPipe(sender) else { return }
        let wanted = !pipe.profile.autoStarts
        pipe.profile.startsAutomatically = wanted
        do { try ProfileStore.standard.save(pipes.map(\.profile)) }
        catch {
            pipe.profile.startsAutomatically = !wanted
            showError(error)
            return
        }
        refresh()
    }

    @objc private func copyPipe(_ sender: NSMenuItem) {
        guard let pipe = selectedPipe(sender) else { return }
        let text = pipe.profile.mode == .share ? pipe.ticket : "127.0.0.1:\(pipe.profile.port)"
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func renamePipe(_ sender: NSMenuItem) {
        guard let pipe = selectedPipe(sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(pipe.profile.name)"
        alert.informativeText = "The pipe keeps its ticket, its port and its saved identity."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = pipe.profile.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var renamed = pipe.profile
        renamed.name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard renamed.name != pipe.profile.name else { return }
        do {
            // Write first. A name the store rejects must leave the running
            // pipe and the menu exactly as they were.
            try ProfileStore.standard.save(pipes.map { $0.profile.id == renamed.id ? renamed : $0.profile })
            pipe.profile = renamed
            buildMenu()
            refresh()
        } catch { showError(error) }
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

    @objc private func exportAndroid() {
        do {
            let profiles = try ProfileStore.standard.load()
            guard !profiles.isEmpty else {
                throw PipeError.invalid("There are no pipes to export.")
            }
            let config = try PatchpipeExport.config(for: profiles, secret: IdentityStore.secret(for:))
            let contents = try PatchpipeExport.encode(config)

            let panel = NSSavePanel()
            panel.title = "Export pipes for Patchpipe"
            panel.nameFieldStringValue = "patchpipe-config.json"
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try contents.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: url.path)

            let alert = NSAlert()
            alert.messageText = "Exported \(config.pipes.count) pipes"
            alert.informativeText = "Move the file to the phone and choose Import config in Patchpipe. The file holds tickets and identity keys, so delete it after the import."
            alert.runModal()
        } catch { showError(error) }
    }

    @objc private func openAndroidApp() {
        NSWorkspace.shared.open(androidAppURL)
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

    // A link behind a SOCKS port opens here too. The browser reaches it through
    // the PAC file PipeDesk writes, so every link opens the same way.
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
