import Foundation
import Darwin
import AudioRouteCore
import AudioRouteEngine

public final class RouterService {
    public let engine: Engine
    private var scenarios: [String: ScenarioSpec] = [:]
    private var restoreErrors: [[String: Any]] = []
    public var shouldStop = false
    private let stateURL: URL

    public init(stateURL: URL = Paths.state.appendingPathComponent("scenarios.json")) throws {
        self.stateURL = stateURL
        engine = Engine()
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            let decoded = try JSONDecoder().decode([String: ScenarioSpec].self, from: data)
            for (id, spec) in decoded {
                try spec.validate()
                scenarios[id] = spec
                do { try engine.apply(spec) }
                catch { restoreErrors.append(["scenario": id, "code": "E_RESTORE_FAILED", "message": String(describing: error)]) }
            }
        }
    }
    private func persist(_ next: [String: ScenarioSpec]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: stateURL, options: .atomic)
    }
    private func dictionary<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
    private func get(_ args: [String: Any]) throws -> ScenarioSpec {
        guard let id = args["id"] as? String, let spec = scenarios[id] else { throw ControlError("E_SCENARIO_NOT_FOUND", "Scenario does not exist") }
        return spec
    }
    private func load(_ args: [String: Any]) throws -> ScenarioSpec {
        guard let text = args["spec"] as? String, let data = text.data(using: .utf8) else { throw ControlError("E_USAGE", "A scenario document is required") }
        let spec = try ScenarioSpec.load(data: data)
        try spec.validate()
        return spec
    }
    private func apply(_ spec: ScenarioSpec) throws -> [String: Any] {
        let id = spec.scenario.id
        var created: [String] = []
        var next = scenarios; next[id] = spec
        do {
            for (outputID, output) in spec.outputs.sorted(by: { $0.key < $1.key }) where output.type == "virtual_input" && output.virtualDevice == nil && output.device == nil {
                let result = try VirtualRegistry.create(name: output.name ?? outputID, input: output.channels.channelCount, output: 0, dryRun: false)
                if result["changed"] as? Bool == true, let device = result["device"] as? [String: Any], let createdID = device["id"] as? String { created.append(createdID) }
            }
            if scenarios[id] == spec {
                try engine.apply(spec)
                engine.reconcile()
                return ["changed": !created.isEmpty, "scenario": id, "status": engine.status(id: id)]
            }
            try engine.apply(spec) { try persist(next) }
        } catch {
            for createdID in created { _ = try? VirtualRegistry.delete(id: createdID, yes: true, dryRun: false) }
            throw error
        }
        scenarios = next
        return ["changed": true, "scenario": id, "status": engine.status(id: id)]
    }
    public func handle(_ request: [String: Any]) -> [String: Any] {
        do {
            guard request["protocol_version"] as? Int == Wire.version else { throw ControlError("E_PROTOCOL_VERSION", "Expected protocol_version 1") }
            let args = request["arguments"] as? [String: Any] ?? [:]
            let result = try dispatch(request["command"] as? String ?? "", args)
            return ["protocol_version": Wire.version, "ok": true, "result": result]
        } catch { return Wire.failure(error) }
    }
    private func dispatch(_ command: String, _ args: [String: Any]) throws -> Any {
        switch command {
        case "ping": return ["pid": getpid(), "version": AudioRouteVersion.current, "restore_errors": restoreErrors] as [String: Any]
        case "daemon.stop":
            if args["dry_run"] as? Bool == true { return ["changed": false, "would_stop": true] }
            shouldStop = true; return ["stopping": true]
        case "devices.list": return engine.devices()
        case "devices.inspect":
            guard let device = engine.devices().first(where: { $0["id"] as? String == args["id"] as? String }) else { throw ControlError("E_DEVICE_NOT_FOUND", "No device matches that stable ID") }
            return device
        case "apps.list": return engine.apps()
        case "apps.playing": return engine.apps().filter { $0["audio_active"] as? Bool == true }
        case "permissions": return engine.permissions()
        case "inspect": return ["devices": engine.devices(), "apps": engine.apps(), "permissions": engine.permissions(), "scenarios": scenarios.keys.sorted()] as [String: Any]
        case "virtual.list": return try VirtualRegistry.list().map { try VirtualRegistry.inspect(id: $0["id"] as? String ?? "", devices: engine.devices()) }
        case "virtual.inspect": return try VirtualRegistry.inspect(id: args["id"] as? String ?? "", devices: engine.devices())
        case "virtual.create": return try VirtualRegistry.create(name: args["name"] as? String ?? "", input: args["input_channels"] as? Int ?? 2, output: args["output_channels"] as? Int ?? 0, dryRun: args["dry_run"] as? Bool == true)
        case "virtual.delete": return try VirtualRegistry.delete(id: args["id"] as? String ?? "", yes: args["yes"] as? Bool == true, dryRun: args["dry_run"] as? Bool == true)
        case "scenario.list": return scenarios.keys.sorted()
        case "scenario.show", "scenario.export": return try dictionary(get(args))
        case "scenario.validate", "scenario.apply":
            let spec = try load(args)
            if command == "scenario.validate" || args["dry_run"] as? Bool == true {
                return ["valid": true, "changed": false, "scenario": spec.scenario.id, "resolution": try engine.preflight(spec)] as [String: Any]
            }
            return try apply(spec)
        case "scenario.delete":
            let spec = try get(args)
            guard args["yes"] as? Bool == true else { throw ControlError("E_CONFIRMATION_REQUIRED", "Pass --yes to delete a scenario") }
            if args["dry_run"] as? Bool == true { return ["changed": false, "would_delete": spec.scenario.id] }
            var next = scenarios; next.removeValue(forKey: spec.scenario.id)
            try persist(next); engine.remove(id: spec.scenario.id); scenarios = next
            return ["changed": true, "deleted": spec.scenario.id] as [String: Any]
        case "status", "meter", "scenario.verify", "doctor":
            engine.reconcile()
            if let id = args["id"] as? String {
                _ = try get(args)
                var result = engine.status(id: id)
                if command == "scenario.verify" || command == "doctor" {
                    result["verification"] = verification(result)
                    result["diagnostics"] = diagnose([result])
                }
                return result
            }
            let states = scenarios.keys.sorted().map { engine.status(id: $0) }
            return ["daemon_running": true, "scenarios": states, "permissions": engine.permissions(), "restore_errors": restoreErrors, "diagnostics": diagnose(states)] as [String: Any]
        case "level.set":
            var spec = try get(args)
            let input = args["input"] as? String
            let output = args["output"] as? String
            if let output {
                guard var destination = spec.outputs[output] else { throw ControlError("E_OUTPUT_NOT_FOUND", "Unknown output \(output)") }
                if let input {
                    guard var mix = destination.mix[input] else { throw ControlError("E_INPUT_NOT_FOUND", "Input is not in this output's mix") }
                    guard let db = args["db"] as? Double else { throw ControlError("E_USAGE", "Per-output input level requires --db") }
                    mix.gainDB = db; destination.mix[input] = mix
                } else {
                    guard let db = args["master_db"] as? Double else { throw ControlError("E_USAGE", "Output master level requires --master-db") }
                    destination.masterGainDB = db
                }
                spec.outputs[output] = destination
            } else if let input {
                guard var source = spec.inputs[input], let db = args["db"] as? Double else { throw ControlError("E_USAGE", "Input trim requires a valid input and --db") }
                source.trimDB = db; spec.inputs[input] = source
            } else { throw ControlError("E_USAGE", "Specify input:NAME or output:NAME") }
            try spec.validate()
            if args["dry_run"] as? Bool == true { return ["changed": false, "proposed": try dictionary(spec)] }
            return try apply(spec)
        default: throw ControlError("E_USAGE", "Unknown command: \(command)")
        }
    }
    private func diagnose(_ states: [[String: Any]]) -> [String: Any] {
        var issues: [[String: Any]] = []
        var actions: [[String: Any]] = []
        let installed = FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/AudioRoute.driver")
        if !installed { issues.append(["code": "E_DRIVER_NOT_INSTALLED", "severity": "action_required", "message": "Virtual audio requires installation of build/AudioRoute.driver."]) }
        for state in states {
            let id = state["scenario"] as? String ?? ""
            for group in ["inputs", "outputs"] {
                for (name, raw) in state[group] as? [String: Any] ?? [:] {
                    guard let endpoint = raw as? [String: Any] else { continue }
                    if let code = endpoint["issue"] as? String { issues.append(["code": code, "severity": "warning", "scenario": id, "endpoint": name]) }
                    if endpoint["connected"] as? Bool == true && endpoint["callbacks_advancing"] as? Bool != true { issues.append(["code": "E_CALLBACKS_STALLED", "severity": "warning", "scenario": id, "endpoint": name]) }
                }
            }
            for (name, _) in state["virtual_devices"] as? [String: Any] ?? [:] {
                guard let output = scenarios[id]?.outputs[name] else { continue }
                let value: [String: Any] = ["action": "select_input_device", "application": output.consumerApplication ?? "target application", "device": output.name ?? output.virtualDevice ?? name, "scenario": id, "note": "The router can observe input reads but cannot identify which application selected the device."]
                actions.append(value)
            }
            if state["clipping"] as? Bool == true { issues.append(["code": "E_CLIPPING", "severity": "warning", "scenario": id]) }
            if (state["recent_xruns"] as? Int ?? 0) > 0 { issues.append(["code": "E_BUFFER_XRUN", "severity": "warning", "scenario": id]) }
        }
        return ["healthy": issues.isEmpty && states.allSatisfy { $0["working"] as? Bool == true }, "driver_installed": installed, "issues": issues, "requires_user_action": actions]
    }
    private func verification(_ status: [String: Any]) -> [String: Any] {
        // Verification is derived from measured engine state, never from configuration success.
        let working = status["working"] as? Bool ?? false
        return ["working": working, "state": working ? "verified" : "not_verified", "note": "Requires advancing callbacks, signal, healthy buffers and virtual consumers where configured."]
    }
}

public enum Daemon {
    public static func run() throws {
        try Paths.prepare()
        let socketLockPath = (Paths.socket as NSString).deletingLastPathComponent + "/socket.lock"
        let socketLock = Darwin.open(socketLockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard socketLock >= 0 else { throw ControlError("E_IPC_LOCK", "Cannot open socket lock") }
        defer { Darwin.close(socketLock) }
        guard flock(socketLock, LOCK_EX | LOCK_NB) == 0 else { throw ControlError("E_DAEMON_RUNNING", "A daemon already owns this socket directory") }
        let lockPath = Paths.state.appendingPathComponent("daemon.lock").path
        let lock = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ControlError("E_DAEMON_RUNNING", "A daemon already owns this state directory") }
        defer { Darwin.close(lock) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("E_IPC_SOCKET", "Cannot create daemon socket") }
        var ownsSocket = false
        defer { Darwin.close(fd); if ownsSocket { unlink(Paths.socket) } }
        // Never displace another live daemon even if it uses a different state directory.
        if (try? Wire.request("ping")) != nil { throw ControlError("E_DAEMON_RUNNING", "A daemon is already listening on this socket") }
        unlink(Paths.socket)
        var addr = try Wire.address(Paths.socket)
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw ControlError("E_IPC_BIND", "Cannot bind \(Paths.socket): \(String(cString: strerror(errno)))") }
        ownsSocket = true
        chmod(Paths.socket, 0o600)
        guard listen(fd, 16) == 0 else { throw ControlError("E_IPC_LISTEN", "Cannot listen on control socket") }
        let service = try RouterService()
        while !service.shouldStop {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 1000)
            if ready == 0 { service.engine.reconcile(); continue }
            if ready < 0 { if errno == EINTR { continue }; break }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            Wire.configure(client)
            var peerUID: uid_t = 0; var peerGID: gid_t = 0
            if getpeereid(client, &peerUID, &peerGID) == 0 && peerUID == getuid() {
                do { try Wire.send(service.handle(Wire.receive(from: client)), to: client) }
                catch { try? Wire.send(Wire.failure(error), to: client) }
            }
            Darwin.close(client)
        }
    }
}
