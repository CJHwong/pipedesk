import Foundation
import Security

final class PipeController {
    var profile: PipeProfile
    private var process: Process?
    private var retired: [Process] = []
    private var generation = UUID()
    private var listenerStarted = false
    private var retry: Timer?
    private var failures = 0
    private var outputBuffer = ""
    private(set) var wantsConnection = false
    private(set) var ticket: String?
    private(set) var lastError: String?
    var autoReconnect = true {
        didSet { if !autoReconnect { retry?.invalidate(); retry = nil } }
    }
    var onChange: (() -> Void)?

    init(profile: PipeProfile) { self.profile = profile }

    var isRunning: Bool { process?.isRunning ?? false }
    var ready: Bool {
        guard let process, process.isRunning else { return false }
        if profile.mode == .share { return listenerStarted && ticket != nil }
        return processListens(pid: process.processIdentifier, port: profile.port)
    }
    var status: String {
        if ready { return profile.mode == .share ? "Sharing" : "Listening on 127.0.0.1:\(profile.port)" }
        if let lastError { return lastError }
        return wantsConnection ? "Starting..." : "Stopped"
    }

    func start() {
        wantsConnection = true
        guard !isRunning else { return }
        retry?.invalidate()
        generation = UUID()
        lastError = nil
        do {
            try profile.validate()
            guard let binary = DumbpipeBinary.locate() else {
                throw PipeError.invalid("Install Dumbpipe, or choose its executable.")
            }
            if profile.mode == .share { try prepareShare(binary: binary) }
            else { try launch(binary: binary) }
        } catch { failed(error.localizedDescription) }
        onChange?()
    }

    private func prepareShare(binary: String) throws {
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: binary)
        generator.arguments = ["generate-ticket"]
        var environment = ProcessInfo.processInfo.environment
        environment["IROH_SECRET"] = try IdentityStore.secret(for: profile.id)
        generator.environment = environment
        generator.standardInput = FileHandle.nullDevice
        let output = Pipe()
        generator.standardOutput = output
        generator.standardError = output
        try generator.run()
        process = generator
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if generator.isRunning { kill(generator.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().async { [weak self] in
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            generator.waitUntilExit()
            let text = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async {
                self?.finishTicket(generator, output: text, binary: binary)
            }
        }
    }

    private func finishTicket(_ generator: Process, output: String, binary: String) {
        guard process === generator, wantsConnection else { return }
        process = nil
        guard generator.terminationStatus == 0, let stableTicket = Self.findTicket(output) else {
            failed("Dumbpipe could not create a stable ticket.")
            return
        }
        do { try launch(binary: binary, stableTicket: stableTicket) }
        catch { failed(error.localizedDescription) }
        onChange?()
    }

    private static func findTicket(_ text: String) -> String? {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.first { ($0.hasPrefix("endpoint") || $0.hasPrefix("node")) && $0.count > 40 }.map(String.init)
    }

    private func launch(binary: String, stableTicket: String? = nil) throws {
        let child = Process()
        let token = UUID()
        generation = token
        outputBuffer = ""
        ticket = stableTicket
        listenerStarted = false
        child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = profile.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["IROH_SECRET"] = try IdentityStore.secret(for: profile.id)
        environment["RUST_LOG"] = "error"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        child.standardError = errors
        child.terminationHandler = { [weak self] completed in
            DispatchQueue.main.async {
                self?.didExit(token: token, status: completed.terminationStatus)
            }
        }
        try child.run()
        process = child
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            let text = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async { self?.receive(text, token: token) }
        }
        Log.write("Dumbpipe started for profile \(profile.id)")
    }

    private func receive(_ text: String, token: UUID) {
        guard generation == token else { return }
        outputBuffer += text
        while let end = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<end])
            outputBuffer.removeSubrange(...end)
            receiveLine(line)
        }
        if outputBuffer.count > 8192 { outputBuffer = String(outputBuffer.suffix(8192)) }
        onChange?()
    }

    private func receiveLine(_ line: String) {
        // Dumbpipe can print private keys. Never copy raw output to the log.
        guard !line.lowercased().contains("secret") else { return }
        if Self.findTicket(line) != nil {
            listenerStarted = true
            failures = 0
            return
        }
        guard line.lowercased().contains("error") || line.lowercased().contains("failed") else { return }
        lastError = String(line.prefix(200))
    }

    private func didExit(token: UUID, status: Int32) {
        guard generation == token else { return }
        process = nil
        ticket = nil
        guard wantsConnection else { onChange?(); return }
        failed(lastError ?? "Dumbpipe exited (\(status)).")
    }

    private func failed(_ reason: String) {
        lastError = reason
        Log.write("Dumbpipe failed for profile \(profile.id)")
        guard wantsConnection, autoReconnect else { onChange?(); return }
        failures += 1
        let delay = min(60.0, 5.0 * pow(2.0, Double(min(failures - 1, 4))))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.start() }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
        onChange?()
    }

    func stop() {
        wantsConnection = false
        suspend()
        failures = 0
        lastError = nil
        onChange?()
    }

    func suspend() {
        retry?.invalidate()
        retry = nil
        generation = UUID()
        let previous = process
        process = nil
        ticket = nil
        listenerStarted = false
        previous?.terminate()
        retired.removeAll { !$0.isRunning }
        if let previous { retired.append(previous) }
        // A stopped child cannot keep the local port after a quick restart.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let previous, previous.isRunning else { return }
            kill(previous.processIdentifier, SIGKILL)
        }
    }

    func shutdown() {
        stop()
        let deadline = Date().addingTimeInterval(1)
        while retired.contains(where: \.isRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        for child in retired where child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
        }
        retired.removeAll()
    }

    func resume() {
        guard wantsConnection else { return }
        failures = 0
        start()
    }
}

enum IdentityStore {
    static func secret(for identifier: UUID) throws -> String {
        let directory = ProfileStore.standard.directory.appendingPathComponent("keys")
        let path = directory.appendingPathComponent(identifier.uuidString)
        let files = FileManager.default
        if files.fileExists(atPath: path.path) {
            let secret = try String(contentsOf: path, encoding: .utf8)
            guard secret.count == 64, secret.allSatisfy(\.isHexDigit) else {
                throw PipeError.invalid("The saved identity is invalid. Restore its backup.")
            }
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return secret
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PipeError.invalid("Cannot create a secure identity.")
        }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        guard files.createFile(atPath: path.path, contents: Data(secret.utf8),
                               attributes: [.posixPermissions: 0o600]) else {
            throw PipeError.invalid("Cannot save the connection identity.")
        }
        return secret
    }
}
