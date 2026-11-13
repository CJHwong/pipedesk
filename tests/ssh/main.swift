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
let stoppedTunnel = TunnelController(config: config.tunnels[0])
stoppedTunnel.stop()
precondition(stoppedTunnel.status == "Stopped", "A stopped tunnel reported a connection failure")
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

print("SSH import and socket cleanup checks passed")

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--retire-agent" {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    let agents = try LegacyTunnelAgent.find(in: directory, aliases: [CommandLine.arguments[3]])
    precondition(agents.count == 1, "Migration did not select only the duplicate agent")
    try agents[0].retire()
    try agents[0].retire()
    print("Legacy SSH job retirement survives a repeated call")
}
