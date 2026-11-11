import Foundation

func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

let connectID = UUID()
let shareID = UUID()
let connect = PipeProfile(id: connectID, name: "Zulu web", mode: .connect,
                          ticket: "endpointabcdefghijklmnopqrstuvwxyz234567", port: 8765)
let share = PipeProfile(id: shareID, name: "Alpha shell", mode: .share, ticket: "", port: 22)

var asked: [UUID] = []
let config = try PatchpipeExport.config(for: [connect, share]) { identifier in
    asked.append(identifier)
    return String(repeating: "a", count: 64)
}
check(config.format == "patchpipe-config", "Export format")
check(config.version == 1, "Export version")
check(config.autoStart == nil, "Export must leave the boot setting alone")
check(asked == [shareID], "Only a listener needs a saved identity")
check(config.pipes.map(\.name) == ["Alpha shell", "Zulu web"], "Pipes sort by name")

let listener = config.pipes[0]
check(listener.id == shareID.uuidString.lowercased(), "Listener keeps its id")
check(listener.mode == "LISTENER", "Share maps to LISTENER")
check(listener.localPort == 22, "Listener port")
check(listener.ticket.isEmpty, "A listener has no ticket")
check(listener.secretKeyHex == String(repeating: "a", count: 64), "Listener keeps its identity")
check(!listener.enabled, "An imported pipe starts off")
check(listener.autoRetry, "Retry is on")
check(listener.relay == "DEFAULT", "Relay uses the default")
check(listener.notes.isEmpty, "Notes are empty")
check(listener.customRelayUrls.isEmpty, "No custom relays")

let server = config.pipes[1]
check(server.id == connectID.uuidString.lowercased(), "Server keeps its id")
check(server.mode == "SERVER", "Connect maps to SERVER")
check(server.localPort == 8765, "Server port")
check(server.ticket == connect.ticket, "Server keeps its ticket")
check(server.secretKeyHex.isEmpty, "A server has no local identity")

let data = try PatchpipeExport.encode(config)
let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
check(object["format"] as? String == "patchpipe-config", "JSON format")
check(object["version"] as? Int == 1, "JSON version")
check(object["autoStart"] == nil, "JSON omits the boot setting")
let pipes = object["pipes"] as? [[String: Any]] ?? []
check(pipes.count == 2, "JSON holds every pipe")
let fields: Set<String> = ["id", "name", "mode", "localPort", "ticket", "secretKeyHex",
                           "notes", "enabled", "autoRetry", "relay", "customRelayUrls"]
check(Set(pipes[0].keys) == fields, "Patchpipe reads every field by name")
check(Set(pipes[1].keys) == fields, "Patchpipe reads every field by name")

print("Patchpipe export checks passed")
