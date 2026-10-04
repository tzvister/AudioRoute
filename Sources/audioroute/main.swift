import Foundation
import Darwin
import AudioRouteControl


func output(_ value: Any) {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    } catch { FileHandle.standardError.write(Data("Cannot encode response: \(error)\n".utf8)) }
}

func daemonExecutableURL() throws -> URL {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    let sibling = executable.deletingLastPathComponent().appendingPathComponent("audiorouted")
    let bundled = executable.deletingLastPathComponent().appendingPathComponent("AudioRoute.app/Contents/MacOS/audiorouted")
    let installed = URL(fileURLWithPath: "/Applications/AudioRoute.app/Contents/MacOS/audiorouted")
    guard let selected = [bundled, sibling, installed].first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw ControlError("E_DAEMON_MISSING", "AudioRoute.app is missing. Install the AudioRoute macOS package, or run scripts/build.sh for a source checkout. Run audioroute setup for diagnostics.")
    }
    return selected
}

func startDaemon() throws -> [String: Any] {
    if let existing = try? Wire.request("ping") { return existing }
    let selected = try daemonExecutableURL()
    try Paths.prepare()
    let log = Paths.state.appendingPathComponent("daemon.log")
    if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    let logHandle = try FileHandle(forWritingTo: log); try logHandle.seekToEnd()
    let process = Process()
    let useLaunchServices = selected.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app"
    if useLaunchServices {
        // LaunchServices makes AudioRoute the responsible application for TCC,
        // rather than inheriting the terminal or coding agent's identity.
        let app = selected.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", "-n", "-a", app.path, "--stdout", log.path, "--stderr", log.path,
            "--env", "AUDIOROUTE_STATE_DIR=" + Paths.state.path, "--env", "AUDIOROUTE_SOCKET=" + Paths.socket]
    } else {
        process.executableURL = selected
    }
    process.standardInput = FileHandle.nullDevice; process.standardOutput = logHandle; process.standardError = logHandle
    try process.run()
    for _ in 0..<200 {
        if let result = try? Wire.request("ping") { return result }
        if !process.isRunning && (!useLaunchServices || process.terminationStatus != 0) { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    throw ControlError("E_DAEMON_START", "Daemon did not start; inspect \(log.path)")
}

do {
    var tokens = Array(CommandLine.arguments.dropFirst())
    if try handleDiscovery(tokens) { exit(0) }
    if tokens.filter({ $0 != "--json" }).first == "setup" {
        guard tokens.filter({ $0 != "--json" }).dropFirst().allSatisfy({ $0 == "--start" }) else { throw ControlError("E_USAGE", "Expected audioroute setup [--start] [--json].") }
        let report = try setupReport(start: tokens.contains("--start"))
        if tokens.contains("--json") { output(["protocol_version": 1, "ok": true, "result": report]) }
        else { printSetupReport(report) }
        exit(0)
    }
    var flags: Set<String> = []
    for flag in ["--json", "--dry-run", "--yes"] { if tokens.contains(flag) { flags.insert(flag); tokens.removeAll { $0 == flag } } }
    var arguments: [String: Any] = ["dry_run": flags.contains("--dry-run"), "yes": flags.contains("--yes")]
    func option(_ name: String) throws -> String? {
        guard let i = tokens.firstIndex(of: name) else { return nil }
        guard i + 1 < tokens.count else { throw ControlError("E_USAGE", "\(name) requires a value") }
        let value = tokens[i + 1]; tokens.removeSubrange(i...i + 1); return value
    }
    for (flag, key) in [("--db", "db"), ("--master-db", "master_db")] {
        if let value = try option(flag) {
            guard let number = Double(value), number.isFinite else { throw ControlError("E_USAGE", "\(flag) must be finite") }
            arguments[key] = number
        }
    }
    for (flag, key) in [("--input", "input_channels"), ("--output", "output_channels")] {
        if let value = try option(flag) {
            guard let number = Int(value), number >= 0, number <= 32 else { throw ControlError("E_USAGE", "\(flag) must be 0...32") }
            arguments[key] = number
        }
    }
    guard !tokens.contains(where: { $0.hasPrefix("--") }) else { throw ControlError("E_USAGE", "Unknown option") }
    let command: String
    switch tokens.first {
    case "daemon":
        guard tokens.count == 2 else { throw ControlError("E_USAGE", "daemon requires start, stop or status") }
        if tokens[1] == "start" {
            if flags.contains("--dry-run") { output(["protocol_version": 1, "ok": true, "result": ["changed": false, "would_start": (try? Wire.request("ping")) == nil]]); exit(0) }
            output(try startDaemon()); exit(0)
        }
        command = tokens[1] == "stop" ? "daemon.stop" : tokens[1] == "status" ? "ping" : "invalid"
    case "devices", "apps", "scenario", "virtual":
        guard tokens.count >= 2, tokens.count <= 3 else { throw ControlError("E_USAGE", "Expected a subcommand and optional ID/file") }
        command = "\(tokens[0]).\(tokens[1])"
        if tokens.count == 3 {
            if tokens[0] == "scenario" && ["apply", "validate"].contains(tokens[1]) {
                let url = URL(fileURLWithPath: tokens[2])
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 2 * 1024 * 1024 else { throw ControlError("E_USAGE", "Scenario file exceeds 2 MiB") }
                arguments["spec"] = try String(contentsOf: url, encoding: .utf8)
            } else if command == "virtual.create" { arguments["name"] = tokens[2] }
            else { arguments["id"] = tokens[2] }
        }
    case "level":
        guard tokens.count >= 3, tokens[1] == "set" else { throw ControlError("E_USAGE", "Expected level set scenario:ID ...") }
        command = "level.set"
        if arguments["db"] != nil && arguments["master_db"] != nil { throw ControlError("E_USAGE", "Choose --db or --master-db, not both") }
        var targets: Set<String> = []
        for token in tokens.dropFirst(2) {
            let pieces = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, ["scenario", "input", "output"].contains(pieces[0]) else { throw ControlError("E_USAGE", "Unknown level target \(token)") }
            guard targets.insert(pieces[0]).inserted else { throw ControlError("E_USAGE", "Duplicate level target") }
            arguments[pieces[0] == "scenario" ? "id" : pieces[0]] = pieces[1]
        }
    case "status", "meter", "doctor", "inspect", "permissions":
        guard tokens.count <= 2 else { throw ControlError("E_USAGE", "Too many arguments") }
        command = tokens[0]
        if tokens.count == 2 { arguments["id"] = tokens[1] }
    default: throw ControlError("E_USAGE", "Unknown command. Run audioroute --help.")
    }
    let response = try Wire.request(command, arguments: arguments)
    output(response)
    if response["ok"] as? Bool != true {
        let code = (response["error"] as? [String: Any])?["code"] as? String
        exit(code == "E_USAGE" ? 2 : 1)
    }
    if command == "scenario.verify" {
        let result = response["result"] as? [String: Any]
        let verified = result?["verification"] as? [String: Any]
        if verified?["working"] as? Bool != true { exit(4) }
    }
} catch {
    output(Wire.failure(error))
    let code = (error as? ControlError)?.code
    exit(code == "E_USAGE" ? 2 : code == "E_DAEMON_NOT_RUNNING" ? 3 : 1)
}
