import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import AppKit
import AudioRouteCore
import CAudioRT
import VirtualAudioTransport

private let virtualRoot = "/Library/Application Support/AudioRoute"
private func checked(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw EngineError(status == -10863 ? "E_PERMISSION_SYSTEM_AUDIO" : "E_COREAUDIO", "\(operation) failed (Core Audio OSStatus \(status)).") }
}
private func db(_ value: Float) -> Any { value > 0 ? Double(20 * log10(value)) as Any : NSNull() }
private func statsJSON(_ s: ar_stats) -> [String: Any] {
    var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
    let elapsed = s.last_host_time > 0 ? Double(mach_absolute_time() - s.last_host_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9 : Double.infinity
    return ["callbacks": s.callbacks, "frames": s.frames, "callbacks_advancing": elapsed < 1,
        "signal": elapsed < 1 && s.peak >= 0.001, "signal_threshold_dbfs": -60, "peak_dbfs": db(s.peak), "rms_dbfs": db(s.rms),
        "invalid_samples": s.invalid_samples, "frames_delivered_to_device": s.device_frames_written, "nonzero_samples_written": s.device_nonzero_samples_written, "unavailable_output_buffers": s.unavailable_output_buffers, "device_write_host_time": s.device_write_host_time, "underruns": s.underruns, "overruns": s.overruns, "clipped_samples": s.clipped_samples, "clipping": elapsed < 1 && s.peak > 1]
}

private final class SourceNode {
    let pointer: OpaquePointer
    var device: AudioDeviceID?
    var tap: AudioObjectID = 0
    var aggregate: AudioObjectID = 0
    var transport: OpaquePointer?
    var connected = false
    var expectsSignal = false
    var issue: String?
    var resolved = ""
    var applicationRunning: Bool?
    var channels: Int
    let rate: Double
    init(channels: [Int], rate: Double) throws {
        self.channels = channels.count; self.rate = rate
        let indices = channels.map { UInt32($0 - 1) }
        guard let p = indices.withUnsafeBufferPointer({ ar_source_create(UInt32(indices.count), $0.baseAddress, rate) }) else { throw EngineError("E_RESOURCE_LIMIT", "Cannot allocate source audio buffers.") }
        pointer = p
    }
    deinit {
        ar_source_destroy(pointer)
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
        if #available(macOS 14.2, *), tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        if let transport { ar_transport_close(transport) }
    }
}
private final class SinkNode {
    let pointer: OpaquePointer
    var device: AudioDeviceID?
    var transport: OpaquePointer?
    var connected = false
    var expectsSignal = false
    var issue: String?
    var resolved = ""
    var channels: Int
    let rate: Double
    init(channels: [Int], rate: Double, ceiling: Float) throws {
        self.channels = channels.count; self.rate = rate
        let indices = channels.map { UInt32($0 - 1) }
        guard let p = indices.withUnsafeBufferPointer({ ar_sink_create(UInt32(indices.count), $0.baseAddress, rate, ceiling) }) else { throw EngineError("E_RESOURCE_LIMIT", "Cannot allocate destination audio buffers.") }
        pointer = p
    }
    deinit { ar_sink_destroy(pointer); if let transport { ar_transport_close(transport) } }
}
private final class Runtime {
    var spec: ScenarioSpec
    var sources: [String: SourceNode] = [:]
    var sinks: [String: SinkNode] = [:]
    var signature = ""
    var lastError: String?
    var reconnects = 0
    var inputReadBaseline: [String: UInt64] = [:]
    var lastXRuns: UInt64 = 0
    var recentXRunTime: UInt64 = 0
    var lastStatusTime: UInt64 = 0
    init(_ spec: ScenarioSpec) { self.spec = spec }
    func activate(_ value: Bool) {
        for source in sources.values { ar_source_set_active(source.pointer, value) }
        for sink in sinks.values { ar_sink_set_active(sink.pointer, value) }
    }
    func stop() {
        activate(false)
        for source in sources.values { ar_source_stop(source.pointer) }
        for sink in sinks.values { ar_sink_stop(sink.pointer) }
    }
    deinit { stop(); sinks.removeAll(); sources.removeAll() }
}

/// Control-plane API. All Core Audio resources live in this long-running object;
/// its callback path is implemented in C and does not enter Swift.
public final class Engine {
    private var runtimes: [String: Runtime] = [:]
    private let lock = NSRecursiveLock()
    private var tapPermissionObserved: Bool?
    public init() {}
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    public func devices() -> [[String: Any]] { Hardware.allDevices().map { $0.json }.sorted { ($0["id"] as! String) < ($1["id"] as! String) } }
    public func apps() -> [[String: Any]] {
        let processes = Hardware.processes()
        var apps: [[String: Any]] = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier != nil && $0.activationPolicy == .regular }.map { app in
            let audio = processes.filter { $0.pid == app.processIdentifier || $0.bundle == app.bundleIdentifier }
            return ["id": "app:\(app.bundleIdentifier!)", "bundle_id": app.bundleIdentifier!, "name": app.localizedName ?? app.bundleIdentifier!, "pid": app.processIdentifier, "running": true, "playing": audio.contains { $0.playing }, "audio_active": audio.contains { $0.playing }, "processes": audio.map { ["pid": $0.pid, "object_id": $0.id] }, "audio_process_ids": audio.map { $0.id }, "capture_available": !audio.isEmpty, "isolation": "application_processes"]
        }
        let known = Set(apps.compactMap { $0["bundle_id"] as? String })
        for process in processes where !known.contains(process.bundle) {
            apps.append(["id": process.bundle.isEmpty ? "pid:\(process.pid)" : "app:\(process.bundle)", "bundle_id": process.bundle, "name": NSRunningApplication(processIdentifier: process.pid)?.localizedName ?? process.bundle, "pid": process.pid, "running": true, "playing": process.playing, "audio_active": process.playing, "processes": [["pid": process.pid, "object_id": process.id]], "audio_process_ids": [process.id], "capture_available": true, "isolation": "application_processes"])
        }
        return apps.sorted { String(describing: $0["id"]!) < String(describing: $1["id"]!) }
    }
    public func permissions() -> [String: Any] { locked {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) { case .authorized: microphone = "granted"; case .denied: microphone = "denied"; case .restricted: microphone = "restricted"; case .notDetermined: microphone = "not_determined"; @unknown default: microphone = "unknown" }
        return ["microphone": microphone, "system_audio": tapPermissionObserved.map { $0 ? "capture_observed" : "tap_failed" } ?? "unknown", "system_audio_preflight_available": false, "process_taps_available": ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)), "permission_owner": Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, "requires_user_action": microphone == "denied" ? [["action": "grant_microphone_access", "settings": "Privacy & Security > Microphone"]] : []]
    } }
    public func apply(_ spec: ScenarioSpec, beforeCommit: () throws -> Void = {}) throws { try locked {
        try spec.validate()
        if let existing = runtimes[spec.scenario.id], existing.spec == spec { try beforeCommit(); return }
        let replacement = try build(spec)
        try beforeCommit()
        let previous = runtimes[spec.scenario.id]
        previous?.stop()
        replacement.activate(true)
        runtimes[spec.scenario.id] = replacement
    } }
    public func remove(id: String) { locked { runtimes.removeValue(forKey: id)?.stop() } }
    /// The daemon invokes this periodically. Stable UIDs and bundle IDs are resolved
    /// again when hardware/process IDs, rates, or virtual publication change.
    public func reconcile() { locked {
        for (id, runtime) in runtimes where runtime.spec.policy.reconnect {
            let signature = resourceSignature(runtime.spec)
            guard signature != runtime.signature else { continue }
            do {
                let replacement = try build(runtime.spec)
                replacement.reconnects = runtime.reconnects + 1
                runtime.stop(); replacement.activate(true); runtimes[id] = replacement
            } catch { runtime.lastError = String(describing: error) }
        }
    } }
    public func status(id: String) -> [String: Any] { locked {
        guard let runtime = runtimes[id] else { return ["scenario": id, "state": "stopped", "working": false] }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        var inputs: [String: Any] = [:], outputs: [String: Any] = [:], virtual: [String: Any] = [:]
        var degraded = false, allAdvancing = true, signal = false, allRequiredSignal = true, virtualConsumed = true
        var actions: [[String: Any]] = []
        var underruns: UInt64 = 0, overruns: UInt64 = 0, invalidSamples: UInt64 = 0, clipping = false
        for (name, source) in runtime.sources {
            let stats = ar_source_stats(source.pointer); var json = statsJSON(stats)
            if source.tap != 0 && stats.callbacks > 0 { tapPermissionObserved = true }
            json["connected"] = source.connected; json["resolved_device"] = source.resolved; json["channels"] = source.channels; json["sample_rate"] = source.rate
            if let running = source.applicationRunning { json["application_running"] = running; json["tap_active"] = source.tap != 0 }
            if let issue = source.issue { json["issue"] = issue }
            degraded = degraded || !source.connected
            allAdvancing = allAdvancing && (json["callbacks_advancing"] as? Bool == true)
            signal = signal || (json["signal"] as? Bool == true)
            if source.expectsSignal { allRequiredSignal = allRequiredSignal && (json["signal"] as? Bool == true) }
            inputs[name] = json; overruns += stats.overruns; invalidSamples += stats.invalid_samples
        }
        for (name, sink) in runtime.sinks {
            let stats = ar_sink_stats(sink.pointer); var json = statsJSON(stats)
            json["connected"] = sink.connected; json["resolved_device"] = sink.resolved; json["channels"] = sink.channels; json["sample_rate"] = sink.rate
            json["master_gain_db"] = runtime.spec.outputs[name]?.masterGainDB ?? 0
            if let issue = sink.issue { json["issue"] = issue }
            if sink.transport == nil && sink.device != nil {
                let observed = stats.device_write_host_time > 0 && Double(mach_absolute_time() - stats.device_write_host_time) * Double(timebase.numer) / Double(timebase.denom) < 1_000_000_000
                json["device_output_delivery_observed"] = observed
                allAdvancing = allAdvancing && observed
            }
            if let transport = sink.transport {
                var transportStats = ar_transport_stats(); ar_transport_get_stats(transport, &transportStats)
                let published = sink.device != nil
                json["published"] = published; json["active_clients"] = transportStats.active_clients
                json["active_consumers"] = NSNull() // HAL reports total clients, not per-direction readers.
                json["driver_callbacks"] = transportStats.driver_callbacks
                json["frames_delivered_to_driver"] = transportStats.input_frames_read
                let consumed = transportStats.active_clients > 0 && transportStats.input_frames_read > (runtime.inputReadBaseline[name] ?? transportStats.input_frames_read) && transportStats.input_read_host_time > 0 && Double(mach_absolute_time() - transportStats.input_read_host_time) * Double(timebase.numer) / Double(timebase.denom) < 1_000_000_000
                json["input_consumption_observed"] = consumed
                json["consumer_application_verified"] = false
                json["input_read_host_time"] = transportStats.input_read_host_time
                virtualConsumed = virtualConsumed && consumed
                if !consumed { actions.append(["action": "select_input_device", "device": runtime.spec.outputs[name]?.name ?? sink.resolved, "application": runtime.spec.outputs[name]?.consumerApplication ?? "target application"]) }
                json["consumer_verification"] = "HAL input reads are observable; client identity and duplex client intent are unavailable."
                virtual[name] = json
            }
            degraded = degraded || !sink.connected
            allAdvancing = allAdvancing && (json["callbacks_advancing"] as? Bool == true)
            if sink.expectsSignal { allRequiredSignal = allRequiredSignal && (json["signal"] as? Bool == true) }
            clipping = clipping || (json["clipping"] as? Bool == true)
            underruns += stats.underruns; overruns += stats.overruns; invalidSamples += stats.invalid_samples; outputs[name] = json
        }
        var warnings: [[String: String]] = []
        if let lastError = runtime.lastError { warnings.append(["code": "E_RECONNECT_FAILED", "message": lastError]); degraded = true }
        if runtime.spec.policy.clipProtection { warnings.append(["code": "hard_clip_protection", "message": "The configured ceiling uses a hard sample clamp; it is not a transparent look-ahead limiter."]) }
        for sink in runtime.sinks.values {
            if let device = sink.device { let transport = Hardware.value(device, kAudioDevicePropertyTransportType, fallback: UInt32(0)); if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { warnings.append(["code": "bluetooth_latency", "message": "Bluetooth audio adds device and codec latency; low-latency instrument monitoring may be impractical."]) } }
        }
        let xruns = underruns + overruns
        let now = mach_absolute_time()
        let newXRuns = runtime.lastStatusTime == 0 ? xruns : xruns >= runtime.lastXRuns ? xruns - runtime.lastXRuns : xruns
        if newXRuns > 0 { runtime.recentXRunTime = now }
        let recentXRuns = runtime.recentXRunTime > 0 && Double(now - runtime.recentXRunTime) * Double(timebase.numer) / Double(timebase.denom) < 1_000_000_000 ? max(UInt64(1), newXRuns) : 0
        runtime.lastXRuns = xruns; runtime.lastStatusTime = now
        warnings.append(["code": "clock_resampling", "message": "Independent clocks use buffered linear interpolation with bounded drift correction. Graph swaps stop old callbacks before activating replacements and may produce a brief audio gap."])
        return ["scenario": id, "state": degraded ? "degraded" : "running", "working": !degraded && allAdvancing && allRequiredSignal && virtualConsumed && !clipping && recentXRuns == 0 && invalidSamples == 0, "sources": inputs, "inputs": inputs, "outputs": outputs, "virtual_devices": virtual,
            "sample_rate": Set(runtime.sinks.values.map { $0.rate }).count == 1 ? (runtime.sinks.values.first?.rate as Any? ?? NSNull()) : NSNull(), "target_sample_rate": runtime.spec.scenario.targetSampleRate, "clock_model": "independent_destination_clocks", "callbacks_advancing": allAdvancing, "signal_observed": signal, "underruns": underruns, "overruns": overruns, "xruns": underruns + overruns,
            "clipping": clipping, "invalid_samples": invalidSamples, "required_signal_observed": allRequiredSignal, "virtual_input_consumption_observed": virtualConsumed, "recent_xruns": recentXRuns, "requires_user_action": actions, "recent_reconnects": runtime.reconnects, "reconnect_armed": runtime.spec.policy.reconnect, "warnings": warnings]
    } }
    /// Resolves current machine resources without creating taps, opening devices,
    /// writing the virtual registry, or triggering a macOS permission dialog.
    public func preflight(_ spec: ScenarioSpec) throws -> [String: Any] { try locked {
        try spec.validate()
        let devices = Hardware.allDevices(), processes = Hardware.processes(), entries = registry()
        var inputs: [String: Any] = [:], outputs: [String: Any] = [:], issues: [[String: Any]] = []
        for (id, input) in spec.inputs {
            switch input.type {
            case "device_input", "device":
                if let device = try Hardware.resolve(input.device, devices: devices), device.alive {
                    guard input.channels.allSatisfy({ $0 <= device.input }) else { throw EngineError("E_CHANNEL_UNAVAILABLE", "Input \(id) selects absent channels on \(device.name).") }
                    try Hardware.checkFloatFormat(device.id, scope: kAudioObjectPropertyScopeInput)
                    inputs[id] = ["connected": true, "uid": device.uid, "sample_rate": device.rate]
                } else { inputs[id] = ["connected": false]; issues.append(["code": "E_DEVICE_NOT_FOUND", "endpoint": id, "message": "Input will remain silent until the configured device connects."]) }
            case "application_output", "application":
                guard #available(macOS 14.2, *) else { throw EngineError("E_APP_CAPTURE_UNAVAILABLE", "Application capture requires macOS 14.2 or newer.") }
                let application = (input.application ?? "").replacingOccurrences(of: "app:", with: "")
                let matches = processes.filter { $0.bundle == application || application == "pid:\($0.pid)" }
                inputs[id] = ["connected": !matches.isEmpty, "process_ids": matches.map { $0.id }, "capture_permission": "unknown_until_tap_is_started", "isolation": "application_processes"]
                if matches.isEmpty { issues.append(["code": "E_APP_NOT_RUNNING", "endpoint": id, "message": "No Core Audio process currently matches this application; the source will be silent until it appears."]) }
                if input.channels.contains(where: { $0 > 2 }) { throw EngineError("E_CHANNEL_UNAVAILABLE", "Application taps use a stereo mixdown; channel indices must be 1 or 2.") }
            case "virtual_output", "virtual", "pass_through":
                guard let entry = try virtual(input.device ?? input.source ?? "", entries: entries) else { throw EngineError("E_VIRTUAL_DEVICE_NOT_FOUND", "Virtual source \(id) has not been created.") }
                let count = entry["outputChannels"] as? Int ?? 0
                guard count > 0, input.channels == Array(1...count) else { throw EngineError("E_FORMAT_UNSUPPORTED", "Pass-through source must select every virtual output channel in order.") }
                inputs[id] = ["connected": devices.contains { $0.uid == "org.audioroute.virtual.\(entry["id"] ?? "")" }, "virtual_device": entry["id"] ?? ""]
            default: throw EngineError("E_SOURCE_UNSUPPORTED", "Runtime source type \(input.type) is not supported.")
            }
        }
        for (id, output) in spec.outputs {
            switch output.type {
            case "device_output", "device":
                if let device = try Hardware.resolve(output.device, devices: devices), device.alive {
                    guard output.channels.channelIndices.allSatisfy({ $0 <= device.output }) else { throw EngineError("E_CHANNEL_UNAVAILABLE", "Output \(id) selects absent channels on \(device.name).") }
                    try Hardware.checkFloatFormat(device.id, scope: kAudioObjectPropertyScopeOutput)
                    outputs[id] = ["connected": true, "uid": device.uid, "sample_rate": device.rate]
                    if device.transport == kAudioDeviceTransportTypeBluetooth || device.transport == kAudioDeviceTransportTypeBluetoothLE { issues.append(["code": "bluetooth_latency", "endpoint": id, "message": "Bluetooth adds device and codec latency."]) }
                } else { outputs[id] = ["connected": false]; issues.append(["code": "E_OUTPUT_DISCONNECTED", "endpoint": id, "message": "Output will discard audio until the configured device connects."]) }
            case "virtual_input", "virtual", "virtual_output":
                let identifier = output.virtualDevice ?? output.device ?? output.name ?? id
                if let entry = try virtual(identifier, entries: entries) {
                    guard entry["inputChannels"] as? Int == output.channels.channelCount else { throw EngineError("E_FORMAT_UNSUPPORTED", "Virtual destination channel count does not match its published inputs.") }
                    outputs[id] = ["virtual_device": entry["id"] ?? "", "will_create": false]
                } else if output.virtualDevice == nil && output.device == nil { outputs[id] = ["name": output.name ?? id, "will_create": true] }
                else { throw EngineError("E_VIRTUAL_DEVICE_NOT_FOUND", "Virtual destination \(identifier) has not been created.") }
                guard output.channels.channelCount <= 32 else { throw EngineError("E_FORMAT_UNSUPPORTED", "The current HAL driver supports at most 32 channels.") }
                if !FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL/AudioRoute.driver") { issues.append(["code": "E_DRIVER_NOT_INSTALLED", "endpoint": id, "message": "Install the AudioRoute HAL driver before a virtual destination can be consumed."]) }
            default: throw EngineError("E_DESTINATION_UNSUPPORTED", "Runtime destination type \(output.type) is not supported.")
            }
        }
        return ["valid": true, "resolved_inputs": inputs, "resolved_outputs": outputs, "issues": issues, "permissions": permissions(), "side_effects": false]
    } }
    private func registry() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: virtualRoot + "/registry.plist")),
            let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil), let root = value as? [String: Any] else { return [] }
        return root["devices"] as? [[String: Any]] ?? []
    }
    private func virtual(_ identifier: String, entries: [[String: Any]]) throws -> [String: Any]? {
        let id = identifier.replacingOccurrences(of: "virtual:", with: "").replacingOccurrences(of: "org.audioroute.virtual.", with: "").replacingOccurrences(of: "coreaudio:device:", with: "")
        let matches = entries.filter { $0["id"] as? String == id || $0["name"] as? String == identifier }
        if matches.count > 1 { throw EngineError("E_DEVICE_AMBIGUOUS", "Several virtual endpoints match \(identifier).") }
        return matches.first
    }
    private func resourceSignature(_ spec: ScenarioSpec) -> String {
        let physicalIdentifiers = Set(spec.inputs.values.filter { $0.type == "device_input" || $0.type == "device" }.compactMap { $0.device } + spec.outputs.values.filter { $0.type == "device_output" || $0.type == "device" }.compactMap { $0.device })
        let virtualIDs = Set(registry().compactMap { $0["id"] as? String })
        let devices = Hardware.allDevices().filter { device in
            physicalIdentifiers.contains(device.uid) || physicalIdentifiers.contains("coreaudio:device:" + device.uid) || physicalIdentifiers.contains(device.name) || virtualIDs.contains(device.uid.replacingOccurrences(of: "org.audioroute.virtual.", with: ""))
        }.map { "\($0.uid):\($0.id):\($0.rate):\($0.alive):\($0.input):\($0.output)" }.sorted().joined(separator: ";")
        let applications = Set(spec.inputs.values.filter { $0.type == "application_output" || $0.type == "application" }.compactMap { $0.application?.replacingOccurrences(of: "app:", with: "") })
        let processes = Hardware.processes().filter { applications.contains($0.bundle) || applications.contains("pid:\($0.pid)") }.map { "\($0.bundle):\($0.id):\($0.pid)" }.sorted().joined(separator: ";")
        let entries = registry().map { "\($0["id"] ?? ""):\($0["inputChannels"] ?? 0):\($0["outputChannels"] ?? 0):\($0["sampleRate"] ?? 0)" }.sorted().joined(separator: ";")
        return devices + "|" + processes + "|" + entries
    }
    private func build(_ spec: ScenarioSpec) throws -> Runtime {
        let realtimeBufferBytes = spec.outputs.values.reduce(0) { total, output in total + output.mix.keys.reduce(0) { $0 + (spec.inputs[$1]?.channels.count ?? 0) * Int(AR_RING_FRAMES) * MemoryLayout<Float>.size } }
        guard realtimeBufferBytes <= 128 * 1024 * 1024 else { throw EngineError("E_RESOURCE_LIMIT", "Scenario needs more than 128 MiB of realtime edge buffers.") }
        let runtime = Runtime(spec)
        // Starting a Bluetooth microphone can change the playback profile. Keep
        // the pre-start signature so reconcile notices any rate/layout change
        // instead of hiding stale nodes behind a freshly read final signature.
        let initialResourceSignature = resourceSignature(spec)
        let devices = Hardware.allDevices(), processes = Hardware.processes(), entries = registry()
        var virtualSourceIDs = Set<String>(), virtualSinkIDs = Set<String>()
        for (id, input) in spec.inputs.sorted(by: { $0.key < $1.key }) {
            let node: SourceNode
            switch input.type {
            case "device", "device_input":
                let device = try Hardware.resolve(input.device, devices: devices)
                if let device, device.alive {
                    guard input.channels.allSatisfy({ $0 <= device.input }) else { throw EngineError("E_CHANNEL_UNAVAILABLE", "Input \(id) selects channels absent on \(device.name).") }
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .denied || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted { throw EngineError("E_PERMISSION_MICROPHONE", "Microphone access is denied for the daemon. Grant access in System Settings > Privacy & Security > Microphone.") }
                    try Hardware.checkFloatFormat(device.id, scope: kAudioObjectPropertyScopeInput)
                    node = try SourceNode(channels: input.channels, rate: device.rate)
                    node.device = device.id; node.connected = true; node.resolved = device.uid
                } else {
                    node = try SourceNode(channels: input.channels, rate: spec.scenario.targetSampleRate)
                    node.issue = "E_DEVICE_NOT_FOUND"; node.resolved = input.device ?? ""
                }
            case "application", "application_output":
                guard #available(macOS 14.2, *) else { throw EngineError("E_APP_CAPTURE_UNAVAILABLE", "Application capture requires macOS 14.2 or newer.") }
                let bundle = (input.application ?? "").replacingOccurrences(of: "app:", with: "")
                let requestedPID = bundle.hasPrefix("pid:") ? Int32(bundle.dropFirst(4)) : nil
                let matches = processes.filter { requestedPID == nil ? $0.bundle == bundle : $0.pid == requestedPID }
                // The explicit list includes only the requested application's Core Audio processes.
                if matches.isEmpty {
                    node = try SourceNode(channels: input.channels, rate: spec.scenario.targetSampleRate)
                    node.applicationRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundle }
                    node.resolved = bundle; node.issue = "E_APP_NOT_RUNNING"
                } else {
                    let description = CATapDescription(stereoMixdownOfProcesses: matches.map { $0.id })
                    description.name = "AudioRoute \(spec.scenario.id) \(id)"; description.isPrivate = true
                    description.muteBehavior = input.muteOriginal ? .mutedWhenTapped : .unmuted
                    var tap: AudioObjectID = 0
                    let err = AudioHardwareCreateProcessTap(description, &tap)
                    if err != noErr { tapPermissionObserved = false; try checked(err, "Creating application tap for \(bundle)") }
                    var tapOwned = false
                    defer { if !tapOwned && tap != 0 { AudioHardwareDestroyProcessTap(tap) } }
                    let format = Hardware.value(tap, kAudioTapPropertyFormat, fallback: AudioStreamBasicDescription())
                    guard input.channels.allSatisfy({ $0 <= Int(format.mChannelsPerFrame) }), format.mSampleRate > 0 else { throw EngineError("E_FORMAT_UNSUPPORTED", "Tap \(bundle) cannot provide the selected channels.") }
                    do {
                        node = try SourceNode(channels: input.channels, rate: format.mSampleRate)
                        node.tap = tap; tapOwned = true; node.applicationRunning = true; node.resolved = bundle
                        let composition: [String: Any] = [kAudioAggregateDeviceNameKey: "AudioRoute private tap", kAudioAggregateDeviceUIDKey: "org.audioroute.tap.\(UUID().uuidString)", kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
                            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
                        try checked(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &node.aggregate), "Creating tap aggregate")
                        try Hardware.checkFloatFormat(node.aggregate, scope: kAudioObjectPropertyScopeInput)
                        node.device = node.aggregate; node.connected = true
                    } catch { throw error }
                }
            case "virtual", "virtual_output", "pass_through":
                let identifier = input.device ?? input.source ?? ""
                guard let entry = try virtual(identifier, entries: entries), let virtualID = entry["id"] as? String else { throw EngineError("E_VIRTUAL_DEVICE_NOT_FOUND", "Virtual source \(identifier) has not been created.") }
                guard virtualSourceIDs.insert(virtualID).inserted else { throw EngineError("E_ENDPOINT_IN_USE", "Virtual output \(virtualID) can have only one router reader.") }
                let outChannels = entry["outputChannels"] as? Int ?? 0
                guard input.channels == Array(1...max(1, outChannels)), outChannels > 0 else { throw EngineError("E_FORMAT_UNSUPPORTED", "Pass-through source must select every virtual output channel in order.") }
                node = try SourceNode(channels: input.channels, rate: entry["sampleRate"] as? Double ?? 48000)
                node.transport = ar_transport_open(virtualRoot + "/devices/\(virtualID).shm", UInt32(entry["inputChannels"] as? Int ?? 0), UInt32(outChannels), 0)
                guard node.transport != nil else { throw EngineError("E_VIRTUAL_TRANSPORT", "Cannot open shared transport for \(virtualID).") }
                node.device = devices.first { $0.uid == "org.audioroute.virtual.\(virtualID)" }?.id
                node.connected = node.device != nil; node.resolved = virtualID
                if !node.connected { node.issue = "E_DRIVER_NOT_INSTALLED" }
            default: throw EngineError("E_SOURCE_UNSUPPORTED", "Runtime source type \(input.type) is not supported.")
            }
            runtime.sources[id] = node
        }
        for (id, output) in spec.outputs.sorted(by: { $0.key < $1.key }) {
            let node: SinkNode
            let ceiling: Float = spec.policy.clipProtection ? Float(pow(10, spec.policy.limiterCeilingDBFS / 20)) : 0
            switch output.type {
            case "device", "device_output":
                let device = try Hardware.resolve(output.device, devices: devices)
                if let device, device.alive {
                    guard output.channels.channelIndices.allSatisfy({ $0 <= device.output }) else { throw EngineError("E_CHANNEL_UNAVAILABLE", "Output \(id) selects channels absent on \(device.name).") }
                    try Hardware.checkFloatFormat(device.id, scope: kAudioObjectPropertyScopeOutput)
                    node = try SinkNode(channels: output.channels.channelIndices, rate: device.rate, ceiling: ceiling)
                    node.device = device.id; node.connected = true; node.resolved = device.uid
                } else {
                    node = try SinkNode(channels: output.channels.channelIndices, rate: spec.scenario.targetSampleRate, ceiling: ceiling)
                    node.issue = "E_OUTPUT_DISCONNECTED"; node.resolved = output.device ?? ""
                }
            case "virtual", "virtual_input", "virtual_output":
                let identifier = output.virtualDevice ?? output.device ?? output.name ?? id
                guard let entry = try virtual(identifier, entries: entries), let virtualID = entry["id"] as? String else { throw EngineError("E_VIRTUAL_DEVICE_NOT_FOUND", "Virtual destination \(identifier) has not been created.") }
                guard virtualSinkIDs.insert(virtualID).inserted else { throw EngineError("E_ENDPOINT_IN_USE", "Virtual input \(virtualID) can have only one router writer.") }
                let inChannels = entry["inputChannels"] as? Int ?? 0
                guard inChannels == output.channels.channelCount, output.channels.channelIndices == Array(1...max(1, inChannels)), inChannels > 0 else { throw EngineError("E_FORMAT_UNSUPPORTED", "Virtual destination channels must match its published input channels.") }
                node = try SinkNode(channels: output.channels.channelIndices, rate: entry["sampleRate"] as? Double ?? 48000, ceiling: ceiling)
                node.transport = ar_transport_open(virtualRoot + "/devices/\(virtualID).shm", UInt32(inChannels), UInt32(entry["outputChannels"] as? Int ?? 0), 0)
                guard node.transport != nil else { throw EngineError("E_VIRTUAL_TRANSPORT", "Cannot open shared transport for \(virtualID).") }
                node.device = devices.first { $0.uid == "org.audioroute.virtual.\(virtualID)" }?.id
                node.connected = node.device != nil; node.resolved = virtualID
                if !node.connected { node.issue = "E_DRIVER_NOT_INSTALLED" }
            default: throw EngineError("E_DESTINATION_UNSUPPORTED", "Runtime destination type \(output.type) is not supported.")
            }
            runtime.sinks[id] = node
            if let transport = node.transport { var initial = ar_transport_stats(); ar_transport_get_stats(transport, &initial); runtime.inputReadBaseline[id] = initial.input_frames_read }
            for (sourceID, mix) in output.mix.sorted(by: { $0.key < $1.key }) {
                guard let source = runtime.sources[sourceID], let sourceSpec = spec.inputs[sourceID] else { continue }
                let weights = try mix.weights(sourceChannels: source.channels, destinationChannels: node.channels)
                let gain = sourceSpec.mute || output.mute || mix.mute ? 0 : pow(10, (sourceSpec.trimDB + mix.gainDB + output.masterGainDB) / 20)
                let matrix = weights.flatMap { $0.map { Float($0 * gain) } }
                if matrix.contains(where: { $0 != 0 }) { node.expectsSignal = true; source.expectsSignal = true }
                guard matrix.allSatisfy({ $0.isFinite }) else { throw EngineError("E_GAIN_UNSUPPORTED", "Combined matrix weights and gains overflow Float32 PCM.") }
                guard matrix.withUnsafeBufferPointer({ ar_sink_add_route(node.pointer, source.pointer, $0.baseAddress) }) else { throw EngineError("E_RESOURCE_LIMIT", "Cannot allocate independent destination mix.") }
            }
        }
        // Prevent multiple processes/graphs from sharing a single SPSC direction.
        for (id, existing) in runtimes where id != spec.scenario.id {
            if existing.sources.values.contains(where: { $0.transport != nil && virtualSourceIDs.contains($0.resolved) }) || existing.sinks.values.contains(where: { $0.transport != nil && virtualSinkIDs.contains($0.resolved) }) { throw EngineError("E_ENDPOINT_IN_USE", "A virtual endpoint is already owned by scenario \(id).") }
        }
        // All buffers/matrices exist before any callback starts. New callbacks are
        // silent until apply commits; the previous graph survives startup failures.
        for (id, source) in runtime.sources {
            if let transport = source.transport {
                try checked(ar_source_start_reader(source.pointer, ar_transport_read_output_callback, UnsafeMutableRawPointer(transport)), "Starting virtual source \(id)")
            } else if let device = source.device { try checked(ar_source_start_device(source.pointer, device), "Starting source \(id)") }
        }
        for (id, sink) in runtime.sinks {
            if let transport = sink.transport {
                try checked(ar_sink_start_writer(sink.pointer, ar_transport_write_input_live, UnsafeMutableRawPointer(transport)), "Starting virtual destination \(id)")
            } else if let device = sink.device { try checked(ar_sink_start_device(sink.pointer, device), "Starting destination \(id)") }
            else {
                // A missing destination still consumes its edge buffers; reconnect
                // cannot replay stale audio and the rest of the graph remains live.
                let discard: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<Float>?, UInt32) -> UInt32 = { _, _, count in count }
                try checked(ar_sink_start_writer(sink.pointer, discard, nil), "Starting discard destination \(id)")
            }
        }
        runtime.signature = initialResourceSignature
        return runtime
    }
}
