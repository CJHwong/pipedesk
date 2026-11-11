import Foundation

// Patchpipe's export format. Field names and enum values mirror its SavedPipe
// and ConfigBackup types, so its importer reads this file without changes.
struct PatchpipePipe: Codable {
    var id: String
    var name: String
    var mode: String
    var localPort: Int
    var ticket: String
    var secretKeyHex: String
    var notes: String
    var enabled: Bool
    var autoRetry: Bool
    var relay: String
    var customRelayUrls: String
}

struct PatchpipeConfig: Codable {
    var format: String
    var version: Int
    // Nil leaves the phone's launch setting alone. JSONEncoder omits the key.
    var autoStart: Bool?
    var pipes: [PatchpipePipe]
}

enum PatchpipeExport {
    static let configFormat = "patchpipe-config"
    static let configVersion = 1

    // A listener reuses the saved identity, or it would publish a new ticket.
    static func config(for profiles: [PipeProfile],
                       secret: (UUID) throws -> String) throws -> PatchpipeConfig {
        let pipes = try profiles
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { profile in
                PatchpipePipe(
                    id: profile.id.uuidString.lowercased(),
                    name: profile.name,
                    mode: profile.mode == .connect ? "SERVER" : "LISTENER",
                    localPort: Int(profile.port),
                    ticket: profile.mode == .connect ? profile.ticket : "",
                    secretKeyHex: profile.mode == .share ? try secret(profile.id) : "",
                    notes: "",
                    enabled: false,
                    autoRetry: true,
                    relay: "DEFAULT",
                    customRelayUrls: ""
                )
            }
        return PatchpipeConfig(format: configFormat, version: configVersion,
                               autoStart: nil, pipes: pipes)
    }

    static func encode(_ config: PatchpipeConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }
}
