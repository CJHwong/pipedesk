import Foundation

enum PipeMode: String, Codable {
    case connect, share
}

struct PipeProfile: Codable {
    var id: UUID
    var name: String
    var mode: PipeMode
    var ticket: String
    var port: UInt16
    // Absent from every profile written before this option existed. Those
    // profiles stay stopped at launch, which is what their owner expects.
    var startsAutomatically: Bool? = nil

    // A launchd agent used to hold this pipe up across a restart. PipeDesk
    // owns the process now, so it must restore the pipe itself or the
    // services above it come back to a dead port.
    var autoStarts: Bool { startsAutomatically ?? false }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipeError.invalid("Enter a connection name.")
        }
        guard port > 0 else { throw PipeError.invalid("Enter a port from 1 to 65535.") }
        guard mode == .connect else { return }
        let alphabet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        guard !ticket.isEmpty, ticket.unicodeScalars.allSatisfy(alphabet.contains) else {
            throw PipeError.invalid("Paste a Dumbpipe ticket without spaces or options.")
        }
    }

    var arguments: [String] {
        switch mode {
        case .connect: return ["connect-tcp", "--addr", "127.0.0.1:\(port)", ticket]
        case .share: return ["listen-tcp", "--host", "127.0.0.1:\(port)"]
        }
    }
}

enum PipeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct ProfileStore {
    let directory: URL
    var path: URL { directory.appendingPathComponent("profiles.json") }

    static var standard: ProfileStore {
        let override = ProcessInfo.processInfo.environment["PIPEDESK_CONFIG_DIR"]
        let directory = override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pipedesk")
        return ProfileStore(directory: directory)
    }

    func load() throws -> [PipeProfile] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let contents = try Data(contentsOf: path)
        let profiles = try JSONDecoder().decode([PipeProfile].self, from: contents)
        try validate(profiles)
        return profiles
    }

    func save(_ profiles: [PipeProfile]) throws {
        try validate(profiles)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: path, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private func validate(_ profiles: [PipeProfile]) throws {
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw PipeError.invalid("Each connection must have a unique identifier.")
        }
        try profiles.forEach { try $0.validate() }
    }
}

enum DumbpipeBinary {
    static func locate() -> String? {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser.path
        let selected = UserDefaults.standard.string(forKey: "dumbpipeBinary")
        let candidates = [selected, "\(home)/.local/bin/dumbpipe", "\(home)/.cargo/bin/dumbpipe",
                          "/opt/homebrew/bin/dumbpipe", "/usr/local/bin/dumbpipe"]
        return candidates.compactMap { $0 }.first { files.isExecutableFile(atPath: $0) }
    }
}

func shellQuote(_ argument: String) -> String {
    "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
