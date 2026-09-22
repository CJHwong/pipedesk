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

// A profile written before Start at Launch existed must stay stopped, so the
// flag has to survive a decode that never saw the key.
let legacy = """
[{"id":"\(UUID().uuidString)","name":"Legacy","mode":"connect",
  "ticket":"endpointabcdefghijklmnopqrstuvwxyz234567","port":18081}]
"""
let decoded = try JSONDecoder().decode([PipeProfile].self, from: Data(legacy.utf8))
check(decoded.count == 1, "Legacy profile decodes")
check(decoded[0].startsAutomatically == nil, "Legacy profile has no flag")
check(!decoded[0].autoStarts, "Legacy profile must not start itself")
check(!connect.autoStarts, "A new profile must not start itself")

var starter = connect
starter.startsAutomatically = true
check(starter.autoStarts, "Start at Launch reads back")
let roundTripDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: roundTripDirectory) }
let roundTrip = ProfileStore(directory: roundTripDirectory)
try roundTrip.save([starter, share])
let reloaded = try roundTrip.load()
check(reloaded.first(where: { $0.id == starter.id })?.autoStarts == true, "Start at Launch survives a save")
check(reloaded.first(where: { $0.id == share.id })?.autoStarts == false, "Other profiles stay stopped")

// A rename must carry the ticket, the port and the identity with it. The
// identity file is keyed by id, so a rename that changed the id would
// silently orphan the key and the pipe would need a fresh ticket.
var renamed = starter
renamed.name = "Renamed pipe"
check(renamed.id == starter.id, "Rename changed the identity")
check(renamed.ticket == starter.ticket, "Rename changed the ticket")
check(renamed.port == starter.port, "Rename changed the port")
check(renamed.autoStarts == starter.autoStarts, "Rename changed the start flag")
try roundTrip.save([renamed, share])
check(try roundTrip.load().contains { $0.id == starter.id && $0.name == "Renamed pipe" },
      "Rename did not survive a save")

// A blank name has to be refused at the store, not only in the dialog, and
// the refusal must leave the saved profiles untouched.
var blank = renamed
blank.name = "   "
do {
    try roundTrip.save([blank, share])
    fatalError("A blank name was accepted")
} catch { }
check(try roundTrip.load().first(where: { $0.id == starter.id })?.name == "Renamed pipe",
      "A rejected rename damaged the saved profiles")

print("Profile checks passed")
