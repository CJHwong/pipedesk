import Foundation

func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}
func rejects(_ profile: PipeProfile) {
    do { try profile.validate(); fatalError("Invalid profile accepted") }
    catch { }
}
let identity = UUID()
let connect = PipeProfile(id: identity, name: "Example", mode: .connect,
                          ticket: "endpointabcdefghijklmnopqrstuvwxyz234567", port: 18080)
try connect.validate()
check(connect.arguments == ["connect-tcp", "--addr", "127.0.0.1:18080", connect.ticket], "Loopback bind")
let share = PipeProfile(id: UUID(), name: "Shell", mode: .share, ticket: "", port: 22)
try share.validate()
check(share.arguments == ["listen-tcp", "--host", "127.0.0.1:22"], "Loopback service")
rejects(PipeProfile(id: identity, name: "", mode: .share, ticket: "", port: 22))
rejects(PipeProfile(id: identity, name: "Bad", mode: .connect, ticket: "--help", port: 22))
rejects(PipeProfile(id: identity, name: "Bad", mode: .connect, ticket: "endpoint bad", port: 22))
rejects(PipeProfile(id: identity, name: "Bad", mode: .share, ticket: "", port: 0))
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let store = ProfileStore(directory: directory)
check(try store.load().isEmpty, "New installation must be empty")
try store.save([connect, share])
check(try store.load().count == 2, "Profiles survive reload")
do {
    try store.save([connect, connect])
    fatalError("Duplicate profiles accepted")
} catch { }
check(try store.load().count == 2, "Failed save preserves profiles")
let permissions = try FileManager.default.attributesOfItem(atPath: store.path.path)[.posixPermissions] as! NSNumber
check(permissions.intValue == 0o600, "Profiles must be private")
check(shellQuote("a'b") == "'a'\\''b'", "Shell quoting")
print("Profile checks passed")
