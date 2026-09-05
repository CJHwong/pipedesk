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
print("SSH import and socket cleanup checks passed")
