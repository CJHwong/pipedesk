import Foundation

let valid = Data("""
{"tunnels":[{"name":"Example","tunnelAlias":"example","probePort":8080,"links":[]}]}
""".utf8)
let config = try Config.decode(valid)
precondition(config.tunnels.count == 1)
precondition(config.tunnels[0].sshArguments.suffix(2) == ["--", "example"])
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
