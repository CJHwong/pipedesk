import Foundation
import Darwin

var cleanup: () -> Void = {}

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("Runtime check failed: \(message)\n".utf8))
        cleanup()
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        exit(1)
    }
}
func spin(until condition: () -> Bool, seconds: TimeInterval = 30) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}
func unusedPort() -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    require(bound == 0, "Cannot reserve a local port")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    return UInt16(bigEndian: address.sin_port)
}
func echo(port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return false }
    let payload = Array("PipeDesk controller transport check\n".utf8)
    guard send(descriptor, payload, payload.count, 0) == payload.count else { return false }
    var response = [UInt8](repeating: 0, count: payload.count)
    let count = recv(descriptor, &response, response.count, MSG_WAITALL)
    return count == payload.count && response == payload
}

func waitForEcho(port: UInt16) -> Bool {
    let deadline = Date().addingTimeInterval(35)
    while Date() < deadline {
        if echo(port: port) { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return false
}

let servicePort = UInt16(CommandLine.arguments[1])!
let sharedProfile = PipeProfile(id: UUID(), name: "Runtime share", mode: .share, ticket: "", port: servicePort)
let share = PipeController(profile: sharedProfile)
cleanup = { share.stop() }
share.autoReconnect = false
share.start()
require(spin(until: { share.ready || share.lastError != nil }), "Share timed out")
require(share.ready, "Share did not become ready: \(share.lastError ?? "unknown")")
let ticket = share.ticket!
let localPort = unusedPort()
let client = PipeController(profile: PipeProfile(id: UUID(), name: "Runtime connect", mode: .connect,
                                                ticket: ticket, port: localPort))
cleanup = { client.stop(); share.stop() }
client.autoReconnect = false
client.start()
require(spin(until: { client.ready || client.lastError != nil }), "Client timed out")
require(client.ready, "Client did not become ready")
require(waitForEcho(port: localPort), "Application controllers did not carry the echo response")
client.stop()
share.stop()
require(spin(until: { !client.isRunning && !share.isRunning }), "Stop failed")
RunLoop.current.run(until: Date().addingTimeInterval(0.5))
share.start()
require(spin(until: { share.ready || share.lastError != nil }), "Restart timed out")
require(share.ready, "Share restart failed")
client.start()
require(spin(until: { client.ready || client.lastError != nil }), "Client restart timed out")
require(client.ready, "Client restart failed")
require(waitForEcho(port: localPort), "Original ticket failed after listener restart")
client.stop()
share.stop()
RunLoop.current.run(until: Date().addingTimeInterval(2.5))
print("Application controllers passed traffic, identity restart, and stop checks")

let folder = ProfileStore.standard.directory
let fakeBinary = folder.appendingPathComponent("ignore-termination.py")
let pidFile = folder.appendingPathComponent("child.pid")
let fakeSource = """
#!/usr/bin/python3
import os
import signal
import time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["PIPEDESK_TEST_PID"], "w") as output:
    output.write(str(os.getpid()))
while True:
    time.sleep(1)
"""
try fakeSource.write(to: fakeBinary, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeBinary.path)
setenv("PIPEDESK_TEST_PID", pidFile.path, 1)
UserDefaults.standard.set(fakeBinary.path, forKey: "dumbpipeBinary")
defer { UserDefaults.standard.removeObject(forKey: "dumbpipeBinary") }
let stubborn = PipeController(profile: PipeProfile(id: UUID(), name: "Termination check", mode: .connect,
                                                  ticket: ticket, port: unusedPort()))
cleanup = { stubborn.shutdown() }
stubborn.start()
require(spin(until: { FileManager.default.fileExists(atPath: pidFile.path) }, seconds: 5), "Fake child did not start")
let childPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
stubborn.shutdown()
require(kill(childPID, 0) != 0, "Child survived application shutdown")
print("Application shutdown removes children that ignore termination")
