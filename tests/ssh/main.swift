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

// A SOCKS tunnel reaches web links on other hosts through the bastion, which
// only allows the destinations in its permitopen list.
let socksTunnel = try Config.decode(Data("""
{"tunnels":[{"name":"AI Gateway stage","tunnelAlias":"stage-bastion","probePort":1080,"socksPort":1080,"links":[
  {"label":"Admin UI","url":"https://gateway.example/ui"},
  {"label":"Plain","url":"http://gateway.example:8080/x"},
  {"label":"Web","url":"http://localhost:7428"},
  {"label":"Screen","url":"vnc://other.example"}]}]}
""".utf8)).tunnels[0]
precondition(socksTunnel.sshArguments.suffix(6) == ["-D", "127.0.0.1:1080", "-L", "7428:127.0.0.1:7428",
                                                    "--", "stage-bastion"],
             "The SOCKS port did not become a loopback -D: \(socksTunnel.sshArguments)")
precondition(socksTunnel.proxiedTarget(of: socksTunnel.links[0]) == ProxiedTarget(host: "gateway.example", port: 443),
             "An https link did not go through the SOCKS port")
precondition(socksTunnel.proxiedTarget(of: socksTunnel.links[1]) == ProxiedTarget(host: "gateway.example", port: 8080),
             "An explicit port on a proxied link was lost")
precondition(socksTunnel.proxiedTarget(of: socksTunnel.links[2]) == nil, "A localhost link went through SOCKS")
precondition(socksTunnel.proxiedTarget(of: socksTunnel.links[3]) == nil, "A non-web link was sent to a browser")
precondition(forwarded.proxiedTarget(of: forwarded.links[2]) == nil,
             "A tunnel without a SOCKS port proxied a link")
precondition(!forwarded.sshArguments.contains("-D"), "A tunnel without a SOCKS port opened one")
for badSocks in [#""socksPort":0,"links":[]"#,
                 #""socksPort":7428,"links":[{"label":"Web","url":"http://localhost:7428"}]"#] {
    do {
        _ = try Config.decode(Data("""
        {"tunnels":[{"name":"Example","tunnelAlias":"example","probePort":7428,\(badSocks)}]}
        """.utf8))
        fatalError("An unusable SOCKS port was accepted: \(badSocks)")
    } catch { precondition(error is PipeError) }
}

// Browsers find the SOCKS ports through a PAC file. Only proxied hosts go
// through a tunnel; every other site stays direct. A host behind two links is
// listed once, and a tunnel without a SOCKS port adds nothing. Apple's PAC
// engine skips "SOCKS5" and reads "SOCKS" as SOCKS5; Chrome and Firefox read
// "SOCKS" as SOCKS4, which sends an address the bastion refuses. So each rule
// lists both, SOCKS5 first.
let expectedPAC = """
// Served by PipeDesk from ssh.json.
function FindProxyForURL(url, host) {
  if (host == "gateway.example") return "SOCKS5 127.0.0.1:1080; SOCKS 127.0.0.1:1080";
  return "DIRECT";
}

"""
precondition(proxyAutoConfig(for: [socksTunnel, forwarded]) == expectedPAC,
             "Wrong PAC file:\n\(proxyAutoConfig(for: [socksTunnel, forwarded]))")
precondition(proxiedHostCount(in: [forwarded]) == 0 && proxiedHostCount(in: [socksTunnel, forwarded]) == 1,
             "Miscounted the proxied hosts")
let response = String(decoding: pacHTTPResponse(expectedPAC), as: UTF8.self)
precondition(response.hasPrefix("HTTP/1.1 200 OK\r\n")
             && response.contains("Content-Type: application/x-ns-proxy-autoconfig\r\n")
             && response.contains("Content-Length: \(expectedPAC.utf8.count)\r\n")
             && response.hasSuffix("\r\n\r\n" + expectedPAC), "Wrong PAC response:\n\(response)")

// A SOCKS port must be free across every tunnel, and must not be the PAC port.
for clash in [
    #"[{"name":"A","tunnelAlias":"a","probePort":1080,"socksPort":1080,"links":[]},{"name":"B","tunnelAlias":"b","probePort":1080,"socksPort":1080,"links":[]}]"#,
    #"[{"name":"A","tunnelAlias":"a","probePort":1080,"socksPort":1080,"links":[]},{"name":"B","tunnelAlias":"b","probePort":1080,"links":[{"label":"Web","url":"http://localhost:1080"}]}]"#,
    #"[{"name":"A","tunnelAlias":"a","probePort":1079,"socksPort":1079,"links":[]}]"#] {
    do {
        _ = try Config.decode(Data(#"{"tunnels":\#(clash)}"#.utf8))
        fatalError("A clashing SOCKS port was accepted: \(clash)")
    } catch { precondition(error is PipeError) }
}

// Queued system proxy work runs only if no newer request came after it.
let requests = LatestRequest()
let olderRequest = requests.next()
let newerRequest = requests.next()
precondition(!requests.isLatest(olderRequest) && requests.isLatest(newerRequest), "An outdated request would run")
DispatchQueue.concurrentPerform(iterations: 1000) { _ in _ = requests.next() }
precondition(requests.next() == newerRequest + 1001, "Concurrent requests lost a count")

// A tunnel can wait for another one, such as a jump that shares its connection.
let ordered = try Config.decode(Data(#"{"tunnels":[{"name":"Office","tunnelAlias":"office","probePort":7427,"links":[]},{"name":"Avery","tunnelAlias":"avery","probePort":7428,"after":"Office","links":[]}]}"#.utf8))
precondition(ordered.tunnels[1].after == "Office" && ordered.tunnels[0].after == nil, "Lost the after field")
for broken in [
    #"[{"name":"A","tunnelAlias":"a","probePort":1,"after":"Missing","links":[]}]"#,
    #"[{"name":"A","tunnelAlias":"a","probePort":1,"after":"A","links":[]}]"#,
    #"[{"name":"A","tunnelAlias":"a","probePort":1,"after":"B","links":[]},{"name":"B","tunnelAlias":"b","probePort":2,"after":"A","links":[]}]"#] {
    do {
        _ = try Config.decode(Data(#"{"tunnels":\#(broken)}"#.utf8))
        fatalError("A broken after was accepted: \(broken)")
    } catch { precondition(error is PipeError) }
}
var officeUp = false
let waiting = TunnelController(config: ordered.tunnels[1])
waiting.autoReconnect = false
waiting.dependencyUp = { officeUp }
waiting.start()
precondition(!waiting.isRunning && waiting.waitingFor == "Office", "Started before the tunnel it waits for")
precondition(tunnelStatusText(wantsConnection: true, state: .down, lastError: nil, retryInSeconds: nil,
                              silentLinks: [], servicesChecked: false, waitingFor: "Office") == "Waiting for Office",
             "Waiting status not shown")
waiting.startIfDependencyUp()
precondition(waiting.waitingFor == "Office", "Left waiting while the other tunnel is down")
waiting.stop()
precondition(waiting.waitingFor == nil, "A stopped tunnel still waits")
officeUp = true
waiting.startIfDependencyUp()
precondition(!waiting.isRunning, "A stopped tunnel started when the other came up")

// A PipeDesk killed outright leaves its ssh children under launchd, holding
// their ports. The next launch stops exactly those: parent 1 and the same
// command line PipeDesk builds. A user's own ssh, or one still owned by a
// running parent, is left alone.
let orphanLine = ([sshPath] + socksTunnel.sshArguments).joined(separator: " ")
let processList = """
  501     1 \(orphanLine)
  502   400 \(orphanLine)
  503     1 /usr/bin/ssh -N stage-bastion
  504     1 /usr/bin/ssh \(socksTunnel.sshArguments.joined(separator: " ")) extra
"""
precondition(orphanedTunnelPIDs(processList: processList, tunnels: [socksTunnel, forwarded]) == [501],
             "Wrong orphans: \(orphanedTunnelPIDs(processList: processList, tunnels: [socksTunnel, forwarded]))")

// The macOS automatic proxy setting, one network service at a time.
let ours = "http://127.0.0.1:1079/proxy.pac"
precondition(parseAutoProxy(service: "Wi-Fi", output: "URL: \(ours)\nEnabled: Yes\n")
             == AutoProxySetting(service: "Wi-Fi", url: ours, enabled: true), "Misread an enabled setting")
precondition(parseAutoProxy(service: "Wi-Fi", output: "URL: (null)\nEnabled: No\n")
             == AutoProxySetting(service: "Wi-Fi", url: nil, enabled: false), "Misread an empty setting")
precondition(parseServiceList("An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n*Thunderbolt Bridge\n")
             == ["Wi-Fi", "Thunderbolt Bridge"], "Misread the service list")
// A service with someone else's PAC is left alone. One already on ours needs no change.
let current = [AutoProxySetting(service: "Wi-Fi", url: nil, enabled: false),
               AutoProxySetting(service: "LAN", url: "http://corp/proxy.pac", enabled: true),
               AutoProxySetting(service: "Dock", url: ours, enabled: true),
               AutoProxySetting(service: "Bridge", url: "http://old/proxy.pac", enabled: false)]
precondition(planAutoProxy(current, ours: ours) == AutoProxyPlan(enable: ["Wi-Fi", "Bridge"], skipped: ["LAN"]),
             "Wrong services to change: \(planAutoProxy(current, ours: ours))")
// Restore turns off only what PipeDesk turned on and still holds.
let afterward = [AutoProxySetting(service: "Wi-Fi", url: ours, enabled: true),
                 AutoProxySetting(service: "Bridge", url: "http://someone/else.pac", enabled: true),
                 AutoProxySetting(service: "LAN", url: ours, enabled: true)]
precondition(servicesToRestore(recorded: ["Wi-Fi", "Bridge", "Gone"], current: afterward, ours: ours) == ["Wi-Fi"],
             "Restore touched a service PipeDesk no longer owns")
// The record keeps each service's own PAC URL, so restore can put it back.
// A service recorded twice keeps the URL from before PipeDesk first changed it.
let merged = mergeRecord([ChangedService(service: "Bridge", previousURL: "http://old/proxy.pac")],
                         adding: [ChangedService(service: "Bridge", previousURL: ours),
                                  ChangedService(service: "Wi-Fi", previousURL: nil)])
precondition(merged == [ChangedService(service: "Bridge", previousURL: "http://old/proxy.pac"),
                        ChangedService(service: "Wi-Fi", previousURL: nil)], "Lost a previous URL: \(merged)")
let recordData = try JSONEncoder().encode(merged)
let readBack = try decodeRecord(recordData)
precondition(readBack == merged, "The record did not read back")
// Records written before URLs were kept are a plain list of names.
let olderRecord = try decodeRecord(Data(#"["Wi-Fi","Pixel 6"]"#.utf8))
precondition(olderRecord
             == [ChangedService(service: "Wi-Fi", previousURL: nil), ChangedService(service: "Pixel 6", previousURL: nil)],
             "An older record no longer reads")

// A config edit restarts only the tunnels it changed.
func tunnel(_ name: String, port: UInt16) -> TunnelConfig {
    TunnelConfig(name: name, tunnelAlias: name.lowercased(), shellAlias: nil, probePort: port,
                 links: [], controlPath: nil, restartAgent: nil, socksPort: nil, after: nil)
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

// The SOCKS check, against what OpenSSH does: it replies only after the
// bastion opened the channel, and closes without a reply when permitopen
// refuses the destination.
func readExactly(_ connection: Int32, _ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
        let got = bytes.withUnsafeMutableBytes { recv(connection, $0.baseAddress! + filled, count - filled, 0) }
        guard got > 0 else { return Array(bytes[..<filled]) }
        filled += got
    }
    return bytes
}
let expectedRequest: [UInt8] = [5, 1, 0, 3, 15] + Array("gateway.example".utf8) + [1, 187]
func socksServer(reply: [UInt8]?, holdOpen: Bool) -> UInt16 {
    serve { connection in
        precondition(readExactly(connection, 3) == [5, 1, 0], "Wrong SOCKS greeting")
        _ = [UInt8]([5, 0]).withUnsafeBytes { write(connection, $0.baseAddress, 2) }
        precondition(readExactly(connection, expectedRequest.count) == expectedRequest, "Wrong SOCKS request")
        if let reply { _ = reply.withUnsafeBytes { write(connection, $0.baseAddress, reply.count) } }
        if holdOpen { sleep(3) }
        close(connection)
    }
}
let success: [UInt8] = [5, 0, 0, 1, 0, 0, 0, 0, 1, 187]
precondition(probeThroughSOCKS(socksPort: socksServer(reply: success, holdOpen: true),
                               host: "gateway.example", port: 443, wait: 1) == .answering,
             "A reachable destination read as down")
precondition(probeThroughSOCKS(socksPort: socksServer(reply: nil, holdOpen: false),
                               host: "gateway.example", port: 443, wait: 1) == .notAnswering,
             "A destination the bastion refused read as answering")
precondition(probeThroughSOCKS(socksPort: socksServer(reply: success, holdOpen: false),
                               host: "gateway.example", port: 443, wait: 1) == .notAnswering,
             "A destination that closed at once read as answering")
precondition(probeThroughSOCKS(socksPort: socksServer(reply: [5, 2, 0, 1, 0, 0, 0, 0, 0, 0], holdOpen: true),
                               host: "gateway.example", port: 443, wait: 1) == .notAnswering,
             "A SOCKS failure reply read as answering")
precondition(probeThroughSOCKS(socksPort: testPort, host: "gateway.example", port: 443, wait: 1) == .notAnswering,
             "A closed SOCKS port read as answering")

print("SSH import and socket cleanup checks passed")

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--retire-agent" {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    let agents = try LegacyTunnelAgent.find(in: directory, aliases: [CommandLine.arguments[3]])
    precondition(agents.count == 1, "Migration did not select only the duplicate agent")
    try agents[0].retire()
    try agents[0].retire()
    print("Legacy SSH job retirement survives a repeated call")
}
