import Foundation

struct LegacyTunnelAgent {
    let label: String

    init?(propertyList: [String: Any], aliases: Set<String>) {
        guard let label = propertyList["Label"] as? String, !label.isEmpty,
              let arguments = propertyList["ProgramArguments"] as? [String],
              (propertyList["Program"] as? String ?? arguments.first) == sshPath,
              arguments.first == sshPath,
              let alias = arguments.last, aliases.contains(alias),
              Self.isForward(arguments) else { return nil }
        self.label = label
    }

    // Limit migration to the direct SSH commands the old agents used.
    // Shell wrappers and alternate configurations can serve unrelated users.
    private static func isForward(_ arguments: [String]) -> Bool {
        var position = 1
        var noSession = false
        while position < arguments.count - 1 {
            switch arguments[position] {
            case "-N": noSession = true; position += 1
            case "-o":
                guard position + 2 < arguments.count,
                      Self.isLegacyOption(arguments[position + 1]) else { return false }
                position += 2
            case "--":
                return noSession && position == arguments.count - 2
            default: return false
            }
        }
        return noSession
    }

    private static func isLegacyOption(_ option: String) -> Bool {
        let fields = option.split(separator: "=", maxSplits: 1)
        guard fields.count == 2, !fields[1].isEmpty else { return false }
        return ["batchmode", "exitonforwardfailure", "serveraliveinterval", "serveralivecountmax"]
            .contains(fields[0].lowercased())
    }

    static func find(in directory: URL, aliases: Set<String>) throws -> [LegacyTunnelAgent] {
        guard !aliases.isEmpty, FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return paths.filter { $0.pathExtension == "plist" }.compactMap { path in
            do {
                let contents = try Data(contentsOf: path)
                let decoded = try PropertyListSerialization.propertyList(from: contents, format: nil)
                guard let fields = decoded as? [String: Any] else { return nil }
                return LegacyTunnelAgent(propertyList: fields, aliases: aliases)
            } catch {
                Log.write("Cannot inspect a legacy launch agent: \(error.localizedDescription)")
                return nil
            }
        }
    }

    func retire() throws {
        let target = "gui/\(getuid())/\(label)"
        // Disable first so a login or a failed child cannot restore a second owner.
        _ = try Self.launchctl(["disable", target])
        let loaded = try Self.launchctl(["list"])
        let isLoaded = loaded.split(whereSeparator: \.isNewline).contains {
            $0.split(whereSeparator: \.isWhitespace).last.map(String.init) == label
        }
        if isLoaded { _ = try Self.launchctl(["bootout", target]) }
        Log.write("Disabled duplicate SSH agent \(label); PipeDesk owns the tunnel")
    }

    private static func launchctl(_ arguments: [String]) throws -> String {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        command.arguments = arguments
        let output = Pipe()
        command.standardOutput = output
        command.standardError = FileHandle.nullDevice
        try command.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else {
            throw PipeError.invalid("Cannot retire a duplicate SSH agent (launchctl exit \(command.terminationStatus)).")
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
