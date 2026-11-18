import Foundation
import Network

// MARK: - PAC file

// The macOS automatic proxy setting points here (pacPort is in
// SSHController.swift, where the config checks it). Chrome and Apple's network
// stack do not read a file:// PAC from that setting, so PipeDesk serves it.
let pacURL = "http://127.0.0.1:\(pacPort)/proxy.pac"

// Sends each proxied host to its tunnel's SOCKS port and every other site
// direct. Apple's PAC engine skips "SOCKS5" and reads "SOCKS" as SOCKS5 with
// the host name. Chrome and Firefox read "SOCKS" as SOCKS4, which sends an
// address that a bastion allowing hosts by name refuses. So each rule lists
// both, SOCKS5 first. A host listed twice keeps the first tunnel that names it.
func proxyAutoConfig(for tunnels: [TunnelConfig]) -> String {
    var seen = Set<String>()
    var rules: [String] = []
    for tunnel in tunnels {
        guard let socks = tunnel.socksPort else { continue }
        for target in tunnel.links.compactMap(tunnel.proxiedTarget(of:)) where seen.insert(target.host).inserted {
            let proxy = "SOCKS5 127.0.0.1:\(socks); SOCKS 127.0.0.1:\(socks)"
            rules.append("  if (host == \(javaScriptString(target.host))) return \"\(proxy)\";")
        }
    }
    return (["// Served by PipeDesk from ssh.json.", "function FindProxyForURL(url, host) {"]
            + rules + ["  return \"DIRECT\";", "}", ""]).joined(separator: "\n")
}

func proxiedHostCount(in tunnels: [TunnelConfig]) -> Int {
    Set(tunnels.flatMap { tunnel in tunnel.links.compactMap(tunnel.proxiedTarget(of:)).map(\.host) }).count
}

// A host name as a quoted JavaScript string. JSON string syntax is valid
// JavaScript, so the encoder handles any quote or backslash.
private func javaScriptString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode(value), let quoted = String(data: data, encoding: .utf8)
    else { return "\"\"" }
    return quoted
}

func pacHTTPResponse(_ text: String) -> Data {
    let body = Data(text.utf8)
    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"
        + "Content-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
    return Data(head.utf8) + body
}

// Answers every request on 127.0.0.1:1079 with the current PAC text. The
// path does not matter: the system setting is the only client.
//
// The setting may point here only while this listener holds the port. If
// another process held it, browsers would load that process's PAC, which can
// send any site anywhere. So callers act in `whenReady`, never before.
final class PACServer {
    private let queue = DispatchQueue(label: "app.pipedesk.pac")
    private var listener: NWListener?
    private var ready = false
    private var waiting: [() -> Void] = []
    private var text = ""
    var onFailure: ((String) -> Void)?

    func serve(_ newText: String, whenReady: @escaping () -> Void) {
        queue.async {
            self.text = newText
            if self.ready { whenReady(); return }
            self.waiting.append(whenReady)
            if self.listener == nil { self.startListening() }
        }
    }

    func stop() {
        queue.sync { reset() }
    }

    private func reset() {
        listener?.cancel()
        listener = nil
        ready = false
        waiting = []
    }

    private func startListening() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: pacPort)!)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready = true
                    Log.write("PAC server listening on \(pacURL)")
                    let callbacks = self.waiting
                    self.waiting = []
                    callbacks.forEach { $0() }
                case .failed(let error):
                    self.fail("PAC server on port \(pacPort) stopped: \(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.answer(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            fail("Cannot serve the PAC file on port \(pacPort): \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        reset()
        Log.write(message)
        onFailure?(message)
    }

    // Reads the request only to know it arrived, then answers and closes. A
    // client that never sends a request is dropped after five seconds.
    private func answer(_ connection: NWConnection) {
        let response = pacHTTPResponse(text)
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

// Numbers each system proxy request. networksetup calls queue up behind each
// other, and a burst of network changes can queue several. Only the latest
// request still matters, so older ones skip their calls, and quit does not
// wait behind them.
final class LatestRequest {
    private let lock = NSLock()
    private var latest = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        latest += 1
        return latest
    }

    func isLatest(_ request: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request == latest
    }
}

// MARK: - macOS automatic proxy setting

struct AutoProxySetting: Equatable {
    let service: String
    let url: String?
    let enabled: Bool
}

struct AutoProxyPlan: Equatable {
    // Services to point at PipeDesk's PAC.
    let enable: [String]
    // Services that already use another PAC. PipeDesk leaves them alone.
    let skipped: [String]
}

// networksetup -listallnetworkservices: a note line, then one service per
// line, with "*" in front of a disabled one.
func parseServiceList(_ output: String) -> [String] {
    output.split(separator: "\n").dropFirst()
        .map { $0.hasPrefix("*") ? String($0.dropFirst()) : String($0) }
        .filter { !$0.isEmpty }
}

// networksetup -getautoproxyurl: "URL: <url or (null)>" and "Enabled: Yes|No".
func parseAutoProxy(service: String, output: String) -> AutoProxySetting {
    var url: String?
    var enabled = false
    for line in output.split(separator: "\n") {
        if line.hasPrefix("URL: ") {
            let value = String(line.dropFirst(5))
            url = value == "(null)" ? nil : value
        } else if line.hasPrefix("Enabled: ") {
            enabled = line.hasSuffix("Yes")
        }
    }
    return AutoProxySetting(service: service, url: url, enabled: enabled)
}

func planAutoProxy(_ settings: [AutoProxySetting], ours: String) -> AutoProxyPlan {
    let foreign = settings.filter { $0.enabled && $0.url != ours }
    let enable = settings.filter { !$0.enabled }
    return AutoProxyPlan(enable: enable.map(\.service), skipped: foreign.map(\.service))
}

// Only the services PipeDesk turned on and that still point at its PAC. One
// the user changed since then is theirs now.
func servicesToRestore(recorded: [String], current: [AutoProxySetting], ours: String) -> [String] {
    current.filter { recorded.contains($0.service) && $0.enabled && $0.url == ours }.map(\.service)
}

// A service PipeDesk pointed at its PAC, and the URL it held before. A service
// can keep a URL while its automatic proxy is off; restore puts it back.
struct ChangedService: Codable, Equatable {
    let service: String
    let previousURL: String?
}

// One entry per service, sorted. An entry already recorded wins, because it
// holds the URL from before PipeDesk first changed that service.
func mergeRecord(_ existing: [ChangedService], adding: [ChangedService]) -> [ChangedService] {
    var byService: [String: ChangedService] = [:]
    for entry in adding + existing { byService[entry.service] = entry }
    return byService.values.sorted { $0.service < $1.service }
}

// Records from before previous URLs were kept are a plain list of names.
func decodeRecord(_ data: Data) throws -> [ChangedService] {
    if let entries = try? JSONDecoder().decode([ChangedService].self, from: data) { return entries }
    return try JSONDecoder().decode([String].self, from: data).map { ChangedService(service: $0, previousURL: nil) }
}

// Points the automatic proxy setting of every network service at the PAC
// server, and turns it off again. The list of services PipeDesk changed is
// kept in a file, so a crash does not lose track of them: the next launch
// restores them before anything else.
struct SystemProxy {
    let recordFile: URL

    static var standard: SystemProxy {
        SystemProxy(recordFile: ProfileStore.standard.directory.appendingPathComponent("system-proxy.json"))
    }

    // Returns the services left alone because they use another PAC.
    func apply() throws -> [String] {
        let settings = try currentSettings()
        let plan = planAutoProxy(settings, ours: pacURL)
        var recorded = try readRecord()
        for service in plan.enable {
            let previous = settings.first { $0.service == service }?.url
            // Record first: a crash between the two steps must not lose a change.
            recorded = mergeRecord(recorded, adding: [ChangedService(
                service: service, previousURL: previous == pacURL ? nil : previous)])
            try writeRecord(recorded)
            _ = try networkSetup(["-setautoproxyurl", service, pacURL])
            Log.write("system proxy: \(service) now uses \(pacURL)")
        }
        for service in plan.skipped {
            Log.write("system proxy: \(service) left alone, it already uses another PAC")
        }
        return plan.skipped
    }

    func restore() throws {
        let recorded = try readRecord()
        guard !recorded.isEmpty else { return }
        let names = recorded.map(\.service)
        for service in servicesToRestore(recorded: names, current: try currentSettings(), ours: pacURL) {
            // Setting a URL also turns automatic proxy on, so turn it off after.
            if let previous = recorded.first(where: { $0.service == service })?.previousURL {
                _ = try networkSetup(["-setautoproxyurl", service, previous])
            }
            _ = try networkSetup(["-setautoproxystate", service, "off"])
            Log.write("system proxy: \(service) restored")
        }
        try FileManager.default.removeItem(at: recordFile)
    }

    private func currentSettings() throws -> [AutoProxySetting] {
        try parseServiceList(networkSetup(["-listallnetworkservices"])).map { service in
            parseAutoProxy(service: service, output: try networkSetup(["-getautoproxyurl", service]))
        }
    }

    private func readRecord() throws -> [ChangedService] {
        guard FileManager.default.fileExists(atPath: recordFile.path) else { return [] }
        return try decodeRecord(Data(contentsOf: recordFile))
    }

    private func writeRecord(_ entries: [ChangedService]) throws {
        try JSONEncoder().encode(entries).write(to: recordFile, options: .atomic)
    }

    private func networkSetup(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PipeError.invalid("networksetup \(arguments.joined(separator: " ")) failed: \(detail)")
        }
        return text
    }
}
