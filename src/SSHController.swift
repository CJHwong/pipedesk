import AppKit

let sshPath = "/usr/bin/ssh"
// The port of the PAC file PipeDesk serves for the system proxy setting.
let pacPort: UInt16 = 1079

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
    // The service's port on the remote, when it differs from the local one.
    // Screen Sharing listens on 5900 everywhere, so a second remote needs
    // another local port for it.
    var remotePort: UInt16?

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

    // The ssh -L value that carries this link. The remote services listen
    // only on the remote's own loopback, so every local link needs one.
    var forward: String? {
        guard let local = localPort else { return nil }
        return "\(local):127.0.0.1:\(remotePort ?? local)"
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
    // A SOCKS port, for a bastion that may only reach listed hosts. A single
    // -L forward cannot serve a web app that redirects to its own host, so the
    // browser goes through this port and the bastion resolves each host.
    let socksPort: UInt16?
    // The name of another tunnel this one starts after. A jump that shares
    // that tunnel's ssh connection must not start first, or it opens its own.
    let after: String?

    var expandedControlPath: String? {
        controlPath.map { ($0 as NSString).expandingTildeInPath }
    }

    var sshArguments: [String] {
        ["-N",
         "-o", "BatchMode=yes",
         "-o", "ExitOnForwardFailure=yes",
         "-o", "ServerAliveInterval=30",
         "-o", "ServerAliveCountMax=3"]
            // The forwards live here rather than in the ssh config, so a link
            // and its forward cannot drift apart. ssh drops a forward that
            // repeats one from the config, so an old config still works.
            + (socksPort.map { ["-D", "127.0.0.1:\($0)"] } ?? [])
            + links.compactMap(\.forward).flatMap { ["-L", $0] }
            + ["--", tunnelAlias]
    }

    // Where a link goes through the SOCKS port: a web link to a host other
    // than this Mac. Other links keep their own forward, or open directly.
    func proxiedTarget(of link: Link) -> ProxiedTarget? {
        guard socksPort != nil, link.localPort == nil,
              let parsed = URL(string: link.url), let host = parsed.host else { return nil }
        let defaultPort: UInt16
        switch parsed.scheme {
        case "https": defaultPort = 443
        case "http": defaultPort = 80
        default: return nil
        }
        guard let port = parsed.port.map({ UInt16(exactly: $0) }) ?? defaultPort else { return nil }
        return ProxiedTarget(host: host, port: port)
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
            for link in tunnel.links where link.remotePort != nil {
                guard link.remotePort != 0, link.localPort != nil else {
                    throw PipeError.invalid("\(tunnel.name): \(link.label) needs a localhost URL and a remotePort from 1 to 65535.")
                }
            }
        }
        try checkSOCKSPorts(config.tunnels)
        try checkStartOrder(config.tunnels)
        return config
    }

}

// Each SOCKS port is a listener of its own, so it must not repeat across
// tunnels, match any link's local port, or take the PAC port. Otherwise one
// ssh fails to bind and its tunnel retries forever.
private func checkSOCKSPorts(_ tunnels: [TunnelConfig]) throws {
    let linkPorts = tunnels.flatMap { $0.links.compactMap(\.localPort) }
    var socksPorts = Set<UInt16>()
    for tunnel in tunnels {
        guard let socks = tunnel.socksPort else { continue }
        guard socks > 0, socks != pacPort, !linkPorts.contains(socks), socksPorts.insert(socks).inserted else {
            throw PipeError.invalid("\(tunnel.name): socksPort \(socks) needs a port from 1 to 65535 that no other "
                + "socksPort or link uses, and not \(pacPort), which serves the proxy file.")
        }
    }
}

// A tunnel waits for one other tunnel, and that one waits for none. One level
// covers a jump host, and no chain of waits can loop back on itself.
private func checkStartOrder(_ tunnels: [TunnelConfig]) throws {
    for tunnel in tunnels {
        guard let after = tunnel.after else { continue }
        guard after != tunnel.name, let target = tunnels.first(where: { $0.name == after }), target.after == nil else {
            throw PipeError.invalid("\(tunnel.name): after must name another tunnel, one that has no after of its own.")
        }
    }
}

struct ProxiedTarget: Equatable {
    let host: String
    let port: UInt16
}

// MARK: - Orphans

// A PipeDesk killed outright (SIGKILL, a crash) cannot stop its ssh children.
// They move under launchd and keep their forwarded ports, so every tunnel of
// the next launch fails with "Address already in use". These are the ones to
// stop: parent 1 and exactly the command line PipeDesk builds for a tunnel.
// `processList` is `ps -axo pid=,ppid=,args=`.
func orphanedTunnelPIDs(processList: String, tunnels: [TunnelConfig]) -> [pid_t] {
    let ours = Set(tunnels.map { ([sshPath] + $0.sshArguments).joined(separator: " ") })
    return processList.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = pid_t(fields[0]), fields[1] == "1",
              ours.contains(String(fields[2])) else { return nil }
        return pid
    }
}

// Stops the orphans and waits for their ports to free, up to two seconds,
// then kills any that ignored SIGTERM.
func stopOrphanedTunnels(for tunnels: [TunnelConfig]) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,ppid=,args="]
    process.standardOutput = output
    do { try process.run() } catch {
        Log.write("cannot list processes to find orphaned tunnels: \(error.localizedDescription)")
        return
    }
    let list = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    let orphans = orphanedTunnelPIDs(processList: list, tunnels: tunnels)
    guard !orphans.isEmpty else { return }
    Log.write("stopping \(orphans.count) ssh tunnel(s) left by an earlier PipeDesk: \(orphans)")
    orphans.forEach { kill($0, SIGTERM) }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, orphans.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
    for pid in orphans where kill(pid, 0) == 0 {
        Log.write("ssh \(pid) ignored SIGTERM, killing it")
        kill(pid, SIGKILL)
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
    guard let descriptor = connectLoopback(port: port) else { return .notAnswering }
    defer { close(descriptor) }
    return awaitService(descriptor, wait: wait)
}

// Whether a destination answers through a SOCKS tunnel.
//
// OpenSSH replies to a SOCKS request only after the bastion opened its end,
// and closes without a reply when the bastion refuses, as permitopen does for
// an unlisted host. A success reply is not enough on its own: the destination
// can still close at once, so the same wait as a forwarded port follows.
func probeThroughSOCKS(socksPort: UInt16, host: String, port: UInt16, wait: TimeInterval = 2) -> ServiceHealth {
    let name = Array(host.utf8)
    guard name.count <= 255, let descriptor = connectLoopback(port: socksPort) else { return .notAnswering }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: Int(wait.rounded(.up)), tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    // No authentication: the tunnel is already the user's own ssh session.
    guard sendAll(descriptor, [5, 1, 0]), receive(descriptor, count: 2) == [5, 0] else { return .notAnswering }
    let request: [UInt8] = [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xff)]
    guard sendAll(descriptor, request),
          let head = receive(descriptor, count: 4), head[0] == 5, head[1] == 0 else { return .notAnswering }
    let addressLength: Int
    switch head[3] {
    case 1: addressLength = 4
    case 4: addressLength = 16
    case 3:
        guard let length = receive(descriptor, count: 1) else { return .notAnswering }
        addressLength = Int(length[0])
    default: return .notAnswering
    }
    guard receive(descriptor, count: addressLength + 2) != nil else { return .notAnswering }
    return awaitService(descriptor, wait: wait)
}

private func connectLoopback(port: UInt16) -> Int32? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
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
    guard connected == 0 else { close(descriptor); return nil }
    return descriptor
}

// A connection that stays open, or sends data first, has a live service
// behind it. One that closes within the wait was refused at the far end.
private func awaitService(_ descriptor: Int32, wait: TimeInterval) -> ServiceHealth {
    var watch = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let ready = poll(&watch, 1, Int32(wait * 1000))
    if ready == 0 { return .answering }
    guard ready > 0 else { return .notAnswering }
    var first: UInt8 = 0
    return recv(descriptor, &first, 1, MSG_PEEK) > 0 ? .answering : .notAnswering
}

private func sendAll(_ descriptor: Int32, _ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBytes { send(descriptor, $0.baseAddress, bytes.count, 0) } == bytes.count
}

// Exactly `count` bytes, or nil when the peer closes or the timeout passes.
private func receive(_ descriptor: Int32, count: Int) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
        let got = bytes.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress! + filled, count - filled, 0) }
        guard got > 0 else { return nil }
        filled += got
    }
    return bytes
}

// MARK: - Status text

// One line per remote. "Connected" means every checked service answered, not
// only that ssh holds the local port.
func tunnelStatusText(wantsConnection: Bool, state: TunnelState, lastError: String?,
                      retryInSeconds: Int?, silentLinks: [String], servicesChecked: Bool,
                      waitingFor: String? = nil) -> String {
    guard wantsConnection else { return "Off" }
    if let waitingFor { return "Waiting for \(waitingFor)" }
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
    // Set for a tunnel with `after`. Answers whether that tunnel is up.
    var dependencyUp: () -> Bool = { true }
    private(set) var waitingFor: String?

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
        if let after = config.after, !dependencyUp() {
            if waitingFor == nil { Log.write("\(config.name): waiting for \(after)") }
            waitingFor = after
            onStateChange?()
            return
        }
        waitingFor = nil
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

    // Called on every refresh. A tunnel parked in start() goes once the tunnel
    // it waits for is up.
    func startIfDependencyUp() {
        guard waitingFor != nil, userWantsTunnel, !suspendedForSleep, dependencyUp() else { return }
        start()
    }

    func stop() {
        userWantsTunnel = false
        waitingFor = nil
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
        guard userWantsTunnel, isRunning || nextRetry != nil || waitingFor != nil else { return }
        suspendedForSleep = true
        waitingFor = nil
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
