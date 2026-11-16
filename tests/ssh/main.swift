import Foundation

let valid = Data("""
{"tunnels":[{"name":"Example","tunnelAlias":"example","probePort":8080,"links":[]}]}
""".utf8)
let config = try Config.decode(valid)
precondition(config.tunnels.count == 1)
precondition(config.tunnels[0].sshArguments.suffix(2) == ["--", "example"])
let legacyAgent: [String: Any] = [
    "Label": "test.example-forward",
    "ProgramArguments": [sshPath, "-N", "-o", "BatchMode=yes", "example"]
]
let matchedAgent = LegacyTunnelAgent(propertyList: legacyAgent, aliases: ["example"])
precondition(matchedAgent?.label == "test.example-forward", "A duplicate tunnel agent was missed")
precondition(LegacyTunnelAgent(propertyList: legacyAgent, aliases: ["other"]) == nil,
             "An unrelated tunnel agent matched")
var dependencyAgent = legacyAgent
dependencyAgent["ProgramArguments"] = ["/usr/local/bin/dumbpipe", "connect-tcp", "example"]
precondition(LegacyTunnelAgent(propertyList: dependencyAgent, aliases: ["example"]) == nil,
             "A transport dependency matched")
var shellAgent = legacyAgent
shellAgent["ProgramArguments"] = [sshPath, "example"]
precondition(LegacyTunnelAgent(propertyList: shellAgent, aliases: ["example"]) == nil,
             "A shell session matched")
var commandAgent = legacyAgent
commandAgent["ProgramArguments"] = [sshPath, "-N", "other", "example"]
precondition(LegacyTunnelAgent(propertyList: commandAgent, aliases: ["example"]) == nil,
             "A remote command matched")
var alternateConfig = legacyAgent
alternateConfig["ProgramArguments"] = [sshPath, "-N", "-F", "/tmp/other-config", "example"]
precondition(LegacyTunnelAgent(propertyList: alternateConfig, aliases: ["example"]) == nil,
             "A tunnel with another configuration matched")
for override in ["HostName=other.invalid", "Port=2200", "ProxyJump=other", "RemoteCommand=example",
                 "LocalForward=9999:127.0.0.1:80", "RemoteForward=9999:127.0.0.1:80"] {
    var distinctTunnel = legacyAgent
    distinctTunnel["ProgramArguments"] = [sshPath, "-N", "-o", override, "example"]
    precondition(LegacyTunnelAgent(propertyList: distinctTunnel, aliases: ["example"]) == nil,
                 "A distinct tunnel matched: \(override)")
}
// Status wording. "Connected" must mean the service answered, not only that
// ssh holds the local port.
precondition(tunnelStatusText(wantsConnection: false, state: .down, lastError: "boom",
                              retryInSeconds: 5, silentLinks: [], servicesChecked: false) == "Off",
             "A switched-off tunnel reported a failure")
precondition(tunnelStatusText(wantsConnection: true, state: .up, lastError: nil,
                              retryInSeconds: nil, silentLinks: [], servicesChecked: true) == "Connected",
             "A healthy tunnel did not read as connected")
precondition(tunnelStatusText(wantsConnection: true, state: .up, lastError: nil, retryInSeconds: nil,
                              silentLinks: ["Rhapsody", "Open Imagine"], servicesChecked: true)
             == "Tunnel up, Rhapsody, Open Imagine not responding",
             "A dead service behind a live tunnel read as connected")
precondition(tunnelStatusText(wantsConnection: true, state: .up, lastError: nil,
                              retryInSeconds: nil, silentLinks: [], servicesChecked: false)
             == "Tunnel up, checking services...", "An unchecked tunnel claimed its services")
precondition(tunnelStatusText(wantsConnection: true, state: .down, lastError: "ssh: Connection refused",
                              retryInSeconds: 12, silentLinks: [], servicesChecked: false)
             == "Retrying in 12s: Connection refused", "A retrying tunnel hid its reason or its timer")
precondition(tunnelStatusText(wantsConnection: true, state: .down, lastError: nil,
                              retryInSeconds: nil, silentLinks: [], servicesChecked: false) == "Not connected",
             "A down tunnel with no reason read wrong")

precondition(isRefusedForward("channel 6: open failed: connect failed: Connection refused"),
             "A refused forward was not recognised")
precondition(!isRefusedForward("kex_exchange_identification: read: Connection reset by peer"),
             "A connection failure was hidden as a refused forward")

// A link reaches its service only through a local port.
precondition(Link(label: "Web", url: "http://localhost:7427").localPort == 7427, "Missed an explicit port")
precondition(Link(label: "Screen", url: "vnc://localhost").localPort == 5900, "Missed the VNC default port")
precondition(Link(label: "Remote", url: "https://example.com:8443").localPort == nil,
             "A remote link was treated as local")

// Each local link becomes one forward, so the ssh config needs only the host.
let forwarded = try Config.decode(Data("""
{"tunnels":[{"name":"Example","tunnelAlias":"example","probePort":7428,"links":[
  {"label":"Web","url":"http://localhost:7428","remotePort":7427},
  {"label":"Screen","url":"vnc://localhost"},
  {"label":"Docs","url":"https://example.com"}]}]}
""".utf8)).tunnels[0]
precondition(forwarded.sshArguments.suffix(6) == ["-L", "7428:127.0.0.1:7427", "-L", "5900:127.0.0.1:5900",
                                                  "--", "example"],
             "Links did not become forwards: \(forwarded.sshArguments)")
for badLink in [#"{"label":"Web","url":"http://localhost:80","remotePort":0}"#,
                #"{"label":"Docs","url":"https://example.com","remotePort":443}"#] {
    do {
        _ = try Config.decode(Data("""
        {"tunnels":[{"name":"Example","tunnelAlias":"example","probePort":80,"links":[\(badLink)]}]}
        """.utf8))
        fatalError("A link with an unusable remote port was accepted: \(badLink)")
    } catch { precondition(error is PipeError) }
}

// A config edit restarts only the tunnels it changed.
func tunnel(_ name: String, port: UInt16) -> TunnelConfig {
    TunnelConfig(name: name, tunnelAlias: name.lowercased(), shellAlias: nil, probePort: port,
                 links: [], controlPath: nil, restartAgent: nil)
}
let before = [tunnel("Office", port: 7427), tunnel("Avery", port: 7428), tunnel("Spark", port: 8766)]
let after = [tunnel("Spark", port: 8766), tunnel("Office", port: 9000), tunnel("Avery", port: 7428)]
precondition(matchTunnels(current: before, next: after) == [2, nil, 1],
             "Reload restarted an unchanged tunnel or kept a changed one")

let stoppedTunnel = TunnelController(config: config.tunnels[0])
stoppedTunnel.stop()
precondition(!stoppedTunnel.wantsConnection, "A stopped tunnel still wanted a connection")
precondition(connectionSummary(tunnels: 0, pipes: 1, unhealthy: 0)
             == "Tunnels running: 0, pipes running: 1", "A running pipe disappeared from the summary")
precondition(connectionSummary(tunnels: 1, pipes: 1, unhealthy: 1)
             == "Tunnels running: 1, pipes running: 1, unhealthy pipes: 1",
             "The summary hid an unhealthy pipe")
let invalid = Data("""
{"tunnels":[{"name":"Example","tunnelAlias":"-Fbad","probePort":8080,"links":[]}]}
""".utf8)
do {
    _ = try Config.decode(invalid)
    fatalError("An SSH option was accepted as an alias")
} catch { precondition(error is PipeError) }
let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: file) }
try Data("retain this file".utf8).write(to: file)
clearStaleControlSocket(file.path)
precondition(FileManager.default.fileExists(atPath: file.path), "Cleanup removed a regular file")
// The census has to tell a working socket from a stranded one, so build a
// real CLOSE_WAIT rather than trust the constant. Apple spells that state
// TSI_S__CLOSE_WAIT, with two underscores, and the wrong name still compiles
// as a different state.
func loopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = port.bigEndian
    return address
}
func withAddress<T>(_ address: inout sockaddr_in, _ body: (UnsafePointer<sockaddr>) -> T) -> T {
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
    }
}

let listener = socket(AF_INET, SOCK_STREAM, 0)
precondition(listener >= 0, "Cannot open a listening socket")
var reuse: Int32 = 1
setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
var bindAddress = loopbackAddress(port: 0)
precondition(withAddress(&bindAddress) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } == 0,
             "Cannot bind the test listener")
precondition(listen(listener, 8) == 0, "Cannot listen")
var assigned = sockaddr_in()
var assignedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &assigned) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &assignedLength) }
}
let testPort = UInt16(bigEndian: assigned.sin_port)

let bound = censusSockets(pid: getpid(), port: testPort)
precondition(bound.listens, "The census missed a listening socket")
precondition(bound.dead == 0, "A fresh listener reported stranded sockets")

let client = socket(AF_INET, SOCK_STREAM, 0)
var target = loopbackAddress(port: testPort)
precondition(withAddress(&target) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } == 0,
             "Cannot connect to the test listener")
let accepted = accept(listener, nil, nil)
precondition(accepted >= 0, "Cannot accept the test connection")
let live = censusSockets(pid: getpid(), port: testPort)
precondition(live.established == 1, "The census missed a live connection")
precondition(live.dead == 0, "A live connection counted as stranded")

// Close the client and leave the accepted half open. That is the exact shape
// dumbpipe leaves behind: the peer sent FIN and nobody closed this side.
close(client)
usleep(300_000)
let stranded = censusSockets(pid: getpid(), port: testPort)
precondition(stranded.dead == 1, "The census missed a stranded socket, got \(stranded.dead)")
precondition(stranded.established == 0, "A stranded socket still counted as live")
precondition(residentBytes(pid: getpid()) > 0, "Resident size read back as zero")
close(accepted)
close(listener)

// The service check, against the three shapes a forwarded port can take.
// ssh accepts locally and then closes at once when the remote refuses. A live
// service keeps the connection open, or greets first.
func serve(_ behaviour: @escaping (Int32) -> Void) -> UInt16 {
    let server = socket(AF_INET, SOCK_STREAM, 0)
    var any = loopbackAddress(port: 0)
    precondition(withAddress(&any) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } == 0)
    precondition(listen(server, 4) == 0)
    var bound = sockaddr_in()
    var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &boundLength) }
    }
    Thread.detachNewThread {
        let connection = accept(server, nil, nil)
        behaviour(connection)
        close(server)
    }
    return UInt16(bigEndian: bound.sin_port)
}
let silentPort = serve { connection in sleep(3); close(connection) }
precondition(probeLocalService(port: silentPort, wait: 1) == .answering,
             "A service that waits for the client read as down")
let greetingPort = serve { connection in _ = "RFB 003.889\n".withCString { write(connection, $0, 12) }; sleep(2); close(connection) }
precondition(probeLocalService(port: greetingPort, wait: 1) == .answering,
             "A service that greets read as down")
let refusedPort = serve { connection in close(connection) }
precondition(probeLocalService(port: refusedPort, wait: 1) == .notAnswering,
             "A forward whose remote refused read as answering")
precondition(probeLocalService(port: testPort, wait: 1) == .notAnswering,
             "A closed port read as answering")

print("SSH import and socket cleanup checks passed")

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--retire-agent" {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    let agents = try LegacyTunnelAgent.find(in: directory, aliases: [CommandLine.arguments[3]])
    precondition(agents.count == 1, "Migration did not select only the duplicate agent")
    try agents[0].retire()
    try agents[0].retire()
    print("Legacy SSH job retirement survives a repeated call")
}
