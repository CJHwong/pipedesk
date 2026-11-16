import AppKit

let sshPath = "/usr/bin/ssh"

// MARK: - Log

// The menu shows only the state right now, so a tunnel that drops and recovers
// while nobody is watching leaves no trace. Append every edge to a file, next
// to the dumbpipe logs, so an outage can be reconstructed afterwards.
enum Log {
    static let path = ("~/Library/Logs/pipedesk.log" as NSString).expandingTildeInPath

    private static let queue = DispatchQueue(label: "app.pipedesk.log")
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        queue.async {
            guard let bytes = "\(stamp.string(from: Date())) \(message)\n".data(using: .utf8) else { return }
            rotateIfLarge()
            guard let handle = FileHandle(forWritingAtPath: path) else {
                try? bytes.write(to: URL(fileURLWithPath: path))
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        }
    }

    // A remote that stays down retries once a minute forever, so the file needs
    // a ceiling. Keep one previous generation rather than discarding history.
    private static func rotateIfLarge() {
        let files = FileManager.default
        guard let size = try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 1_000_000 else { return }
        try? files.removeItem(atPath: path + ".1")
        try? files.moveItem(atPath: path, toPath: path + ".1")
    }
}

// MARK: - Configuration

struct Link: Codable, Equatable {
    let label: String
    let url: String

    // The local port a link reaches its service through. A link to another
    // host does not go through the tunnel, so it has nothing to check here.
    var localPort: UInt16? {
        guard let parsed = URL(string: url), let host = parsed.host,
              ["localhost", "127.0.0.1", "::1"].contains(host) else { return nil }
        if let port = parsed.port { return UInt16(exactly: port) }
        switch parsed.scheme {
        case "vnc": return 5900
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    // Shown under the label in the menu. "http://localhost:7427" reads better
    // as "localhost:7427", and a scheme alone is not worth a line of its own.
    var detail: String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        if let port = parsed.port { return "\(host):\(port)" }
        return host
    }

    var symbol: String {
        switch URL(string: url)?.scheme {
        case "vnc": return "display"
        case "http", "https": return "safari"
        default: return "arrow.up.right.square"
        }
    }
}

struct TunnelConfig: Codable, Equatable {
    let name: String
    let tunnelAlias: String
    let shellAlias: String?
    let probePort: UInt16
    let links: [Link]
    // Only needed when the ssh config for this host sets ControlPath. A master
    // killed with SIGKILL leaves a socket file that refuses connections, and
    // ssh will not replace it on its own.
    let controlPath: String?
    // A launchd label, for a tunnel that rides on a local service such as a
    // pipe. That service can hold a dead network path across sleep and never
    // recover, which looks exactly like a broken tunnel. Restart it at launch
    // rather than let the tunnel fail and back off against a corpse.
    let restartAgent: String?

    var expandedControlPath: String? {
        controlPath.map { ($0 as NSString).expandingTildeInPath }
    }

    var sshArguments: [String] {
        ["-N",
         "-o", "BatchMode=yes",
         "-o", "ExitOnForwardFailure=yes",
         "-o", "ServerAliveInterval=30",
         "-o", "ServerAliveCountMax=3",
         "--", tunnelAlias]
    }

}

struct Config: Codable {
    let tunnels: [TunnelConfig]

    static var path: String {
        ProfileStore.standard.directory.appendingPathComponent("ssh.json").path
    }

    static func load() -> (config: Config, error: String?) {
        let empty = Config(tunnels: [])
        guard FileManager.default.fileExists(atPath: path) else { return (empty, nil) }
        do {
            let contents = try Data(contentsOf: URL(fileURLWithPath: path))
            let config = try decode(contents)
            return (config, nil)
        } catch { return (empty, "Cannot read SSH profiles: \(error.localizedDescription)") }
    }

    static func decode(_ contents: Data) throws -> Config {
        let config = try JSONDecoder().decode(Config.self, from: contents)
        for tunnel in config.tunnels {
            guard !tunnel.name.isEmpty, !tunnel.tunnelAlias.isEmpty,
                  !tunnel.tunnelAlias.hasPrefix("-"), tunnel.probePort > 0 else {
                throw PipeError.invalid("Each SSH profile needs a name, alias, and port from 1 to 65535.")
            }
        }
        return config
    }

}

// For each tunnel in the new config, the index of an identical running tunnel
// to keep, or nil when it is new or changed. An edit to one tunnel must not
// drop the sessions running through all the others.
func matchTunnels(current: [TunnelConfig], next: [TunnelConfig]) -> [Int?] {
    var unused = Set(current.indices)
    return next.map { tunnel in
        guard let index = current.indices.first(where: { unused.contains($0) && current[$0] == tunnel })
        else { return nil }
        unused.remove(index)
        return index
    }
}

// MARK: - Service check

enum ServiceHealth {
    case answering, notAnswering
}

// Whether the service behind a forwarded port answers.
//
// ssh accepts a forwarded connection locally before it asks the remote side to
// open its end. When nothing listens there, the remote refuses and ssh closes
// the local socket within a round trip. A live service keeps the connection
// open, or sends its greeting first. So the first moments of one connection
// separate the two. This is a separate signal from processListens, which
// proves only that the tunnel itself holds the port.
func probeLocalService(port: UInt16, wait: TimeInterval = 2) -> ServiceHealth {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return .notAnswering }
    defer { close(descriptor) }
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return .notAnswering }
    var watch = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let ready = poll(&watch, 1, Int32(wait * 1000))
    if ready == 0 { return .answering }
    guard ready > 0 else { return .notAnswering }
    var first: UInt8 = 0
    return recv(descriptor, &first, 1, MSG_PEEK) > 0 ? .answering : .notAnswering
}

// MARK: - Status text

// One line per remote. "Connected" means every checked service answered, not
// only that ssh holds the local port.
func tunnelStatusText(wantsConnection: Bool, state: TunnelState, lastError: String?,
                      retryInSeconds: Int?, silentLinks: [String], servicesChecked: Bool) -> String {
    guard wantsConnection else { return "Off" }
    switch state {
    case .starting:
        return "Connecting..."
    case .up:
        if !servicesChecked { return "Tunnel up, checking services..." }
        if silentLinks.isEmpty { return "Connected" }
        return "Tunnel up, \(silentLinks.joined(separator: ", ")) not responding"
    case .down:
        let reason = lastError.map(shortenSSHError) ?? "Not connected"
        guard let seconds = retryInSeconds else { return reason }
        return "Retrying in \(seconds)s: \(reason)"
    }
}

// ssh's report when the remote end of one forwarded connection refuses, as in
// "channel 6: open failed: connect failed: Connection refused".
func isRefusedForward(_ line: String) -> Bool {
    line.hasPrefix("channel ") && line.contains(": open failed: ")
}

func shortenSSHError(_ message: String) -> String {
    let cleaned = message
        .replacingOccurrences(of: "ssh: ", with: "")
        .replacingOccurrences(of: "Warning: ", with: "")
    return cleaned.count > 48 ? String(cleaned.prefix(48)) + "..." : cleaned
}

// MARK: - State

enum TunnelState {
    case down, starting, up

    var label: String {
        switch self {
        case .down: return "Disconnected"
        case .starting: return "Connecting..."
        case .up: return "Connected"
        }
    }
}

// True when a master is actually listening on the control socket. A leftover
// socket file from a killed master looks identical on disk but refuses
// connections, and ssh will not replace it on its own.
func controlSocketIsLive(_ path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        path.utf8CString.withUnsafeBufferPointer { src in
            let n = min(src.count, raw.count - 1)
            raw.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: n)
        }
    }
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    return result == 0
}

func clearStaleControlSocket(_ path: String?) {
    guard let path else { return }
    let fm = FileManager.default
    guard let attributes = try? fm.attributesOfItem(atPath: path),
          attributes[.type] as? FileAttributeType == .typeSocket,
          !controlSocketIsLive(path) else { return }
    do {
        try fm.removeItem(atPath: path)
        Log.write("Removed a stale SSH control socket")
    } catch { Log.write("Cannot remove a stale SSH control socket: \(error.localizedDescription)") }
}

// True when this ssh process itself holds a listening socket on the port.
//
// Connecting to the port instead would answer a different question: it reports
// whether anyone is listening. A tunnel orphaned by an earlier run answers too,
// and so does an unrelated service that happens to use the port, so a dead
// tunnel would report itself healthy. Asking the kernel who owns the socket
// removes the ambiguity, and it costs no forwarded connection to the remote.
//
// Socket ownership proves only local readiness. The remote service can still fail.
// What a child's sockets say about its health.
//
// A process can hold its listening socket perfectly while it is on fire. The
// leaked halves of closed connections stay in the table forever, so counting
// them is the difference between "still bound" and "still working".
struct SocketCensus {
    var listens = false
    var established = 0
    var dead = 0
}

func censusSockets(pid: pid_t, port: UInt16) -> SocketCensus {
    var census = SocketCensus()
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return census }
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(),
                                    count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
    let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
    guard written > 0 else { return census }
    let found = Int(written) / MemoryLayout<proc_fdinfo>.stride
    for entry in descriptors.prefix(found)
    where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        var info = socket_fdinfo()
        let length = proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDSOCKETINFO,
                                    &info, Int32(MemoryLayout<socket_fdinfo>.size))
        guard length > 0, info.psi.soi_kind == SOCKINFO_TCP else { continue }
        let tcp = info.psi.soi_proto.pri_tcp
        let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        guard local == port else { continue }
        switch tcp.tcpsi_state {
        case Int32(TSI_S_LISTEN): census.listens = true
        case Int32(TSI_S_ESTABLISHED): census.established += 1
        // TSI_S__CLOSE_WAIT carries a double underscore in sys/proc_info.h.
        case Int32(TSI_S__CLOSE_WAIT), Int32(TSI_S_CLOSED),
             Int32(TSI_S_LAST_ACK), Int32(TSI_S_CLOSING): census.dead += 1
        default: break
        }
    }
    return census
}

// Resident size of a child, for a human reading the menu. A process that grows
// without bound is degrading even when its socket table looks ordinary.
func residentBytes(pid: pid_t) -> UInt64 {
    var usage = rusage_info_v2()
    let ok = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    return ok == 0 ? usage.ri_resident_size : 0
}

func processListens(pid: pid_t, port: UInt16) -> Bool {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return false }
    var descriptors = [proc_fdinfo](repeating: proc_fdinfo(),
                                    count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
    let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
    guard written > 0 else { return false }
    let found = Int(written) / MemoryLayout<proc_fdinfo>.stride
    for entry in descriptors.prefix(found)
    where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        var info = socket_fdinfo()
        let length = proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDSOCKETINFO,
                                    &info, Int32(MemoryLayout<socket_fdinfo>.size))
        guard length > 0, info.psi.soi_kind == SOCKINFO_TCP else { continue }
        let tcp = info.psi.soi_proto.pri_tcp
        let local = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        if tcp.tcpsi_state == Int32(TSI_S_LISTEN), local == port { return true }
    }
    return false
}

// MARK: - Tunnel

final class TunnelController {
    let config: TunnelConfig
    private var task: Process?
    private var retryTimer: Timer?
    private var errorPipe: Pipe?
    private var failureCount = 0
    private(set) var lastError: String?
    private(set) var nextRetry: Date?
    private var loggedState: TunnelState?
    var autoReconnect = true {
        didSet {
            if !autoReconnect { cancelRetry(); nextRetry = nil }
        }
    }
    var wantsConnection: Bool { userWantsTunnel }
    private var userWantsTunnel = true
    private var suspendedForSleep = false
    var onStateChange: (() -> Void)?

    init(config: TunnelConfig) {
        self.config = config
    }

    var state: TunnelState {
        guard let task, task.isRunning else { return .down }
        return processListens(pid: task.processIdentifier, port: config.probePort)
            ? .up : .starting
    }

    var isRunning: Bool { task?.isRunning ?? false }

    func start() {
        userWantsTunnel = true
        suspendedForSleep = false
        guard !isRunning else { return }
        clearStaleControlSocket(config.expandedControlPath)
        Log.write("\(config.name): starting ssh \(config.tunnelAlias), attempt \(failureCount + 1)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = config.sshArguments
        process.standardOutput = FileHandle.nullDevice
        // ssh writes the reason for a failure to stderr. Keep the last line so
        // the menu can say what went wrong instead of only "Disconnected".
        let errors = Pipe()
        errorPipe = errors
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readErrorOutput(handle.availableData)
        }
        process.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                guard let self, self.task === completed else { return }
                self.handleExit()
            }
        }
        do {
            try process.run()
            task = process
        } catch {
            NSLog("pipedesk: failed to launch ssh for \(config.name): \(error)")
            Log.write("\(config.name): cannot launch ssh: \(error.localizedDescription)")
            task = nil
            lastError = error.localizedDescription
            closeErrorPipe()
            if autoReconnect { scheduleRetry() }
        }
        onStateChange?()
    }

    func stop() {
        userWantsTunnel = false
        failureCount = 0
        nextRetry = nil
        lastError = nil
        cancelRetry()
        task?.terminate()
        task = nil
        closeErrorPipe()
        onStateChange?()
    }

    // A pipe whose writer is gone stays readable forever, because that is what
    // EOF looks like to the kernel. The readability handler would then fire in
    // a tight loop on empty data, once per dead ssh, until the app quits.
    // Unregister the handler and close the descriptor on every path that
    // abandons the process.
    //
    // ssh writes its reason just before it exits, so the last lines can still
    // sit in the pipe. Drain them only when the writer is already gone. On the
    // stop path ssh is still dying, and the read would block the main thread
    // until it did.
    private func closeErrorPipe(drainingRemainder: Bool = false) {
        guard let pipe = errorPipe else { return }
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        if drainingRemainder { readErrorOutput((try? handle.readToEnd()) ?? Data()) }
        try? handle.close()
        errorPipe = nil
    }

    private func readErrorOutput(_ bytes: Data) {
        guard !bytes.isEmpty,
              let text = String(data: bytes, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("secret") }
        // The menu has room for one line, but the log keeps every line.
        // ssh reports the cause first and the summary last, so dropping
        // the earlier lines would throw away the useful half.
        // The exception is a refused forward: each service check of a dead
        // service produces one, twice a minute. The check already logs when
        // a service starts or stops answering, so the repeats only bury events.
        lines.filter { !isRefusedForward($0) }.forEach { Log.write("\(config.name): ssh: \($0)") }
        guard let line = lines.last else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.userWantsTunnel else { return }
            self.lastError = line
            self.onStateChange?()
        }
    }

    private func handleExit() {
        task = nil
        closeErrorPipe(drainingRemainder: true)
        Log.write("\(config.name): ssh exited")
        onStateChange?()
        guard autoReconnect, userWantsTunnel, !suspendedForSleep else {
            Log.write("\(config.name): no retry, tunnel is off")
            return
        }
        scheduleRetry()
    }

    // A remote that is off must not be retried at a fixed short interval.
    // Back off to a one minute ceiling.
    private func scheduleRetry() {
        cancelRetry()
        failureCount += 1
        let delay = min(60.0, 5.0 * pow(2.0, Double(min(failureCount - 1, 4))))
        nextRetry = Date().addingTimeInterval(delay)
        Log.write("\(config.name): retry in \(Int(delay))s, failure \(failureCount)")
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.nextRetry = nil
            self?.start()
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
        onStateChange?()
    }

    // Sleep breaks every forward, and ssh needs up to 90 seconds of keepalives
    // to notice. Drop the process now so wake can start a clean one. This is
    // not the user switching the tunnel off, so their intent survives.
    func suspendForSleep() {
        guard userWantsTunnel, isRunning || nextRetry != nil else { return }
        suspendedForSleep = true
        cancelRetry()
        nextRetry = nil
        task?.terminate()
        task = nil
        closeErrorPipe()
        Log.write("\(config.name): suspended for sleep")
        onStateChange?()
    }

    // Wake must not sit out the remaining backoff. The old failures described a
    // network that no longer exists, so the ladder starts again from the bottom.
    func resumeAfterWake() {
        guard userWantsTunnel else { return }
        cancelRetry()
        nextRetry = nil
        failureCount = 0
        lastError = nil
        Log.write("\(config.name): resuming after wake")
        start()
    }

    // A new network makes the old failures meaningless, the same as wake does.
    // Only a tunnel sitting out a backoff is touched. A running ssh keeps its
    // session, because restarting on every path update would churn tunnels
    // each time a virtual interface comes or goes.
    func retryNowIfWaiting() {
        guard userWantsTunnel, !isRunning, nextRetry != nil else { return }
        cancelRetry()
        nextRetry = nil
        failureCount = 0
        lastError = nil
        Log.write("\(config.name): network changed, retrying now")
        start()
    }

    // The poll owns the only real view of liveness. Report edges here, because
    // logging every poll would bury the transitions under 40 lines a minute.
    func noteState(_ current: TunnelState) {
        guard loggedState != current else { return }
        Log.write("\(config.name): \(loggedState?.label ?? "Unknown") -> \(current.label)")
        loggedState = current
    }

    func noteHealthy() {
        failureCount = 0
        lastError = nil
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
}
