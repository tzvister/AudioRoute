import Foundation

extension ScenarioSpec {
    public func validate() throws {
        guard version == 1 else { throw ConfigurationError("E_CONFIG_VERSION", "Only scenario version 1 is supported.") }
        try identifier(scenario.id, path: "scenario.id")
        guard !scenario.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError("scenario.name cannot be empty.") }
        guard scenario.targetSampleRate.isFinite, (8000...192000).contains(scenario.targetSampleRate) else { throw ConfigurationError("target_sample_rate must be between 8000 and 192000 Hz.") }
        guard ["low", "balanced", "safe"].contains(scenario.latencyMode) else { throw ConfigurationError("latency_mode must be low, balanced, or safe.") }
        guard !inputs.isEmpty, inputs.count <= 64, !outputs.isEmpty, outputs.count <= 64 else { throw ConfigurationError("A scenario requires between 1 and 64 inputs and outputs.") }
        guard policy.disconnectedInput == "silence", policy.disconnectedOutput == "discard" else { throw ConfigurationError("Disconnected inputs must use silence and outputs must use discard.") }
        guard policy.limiterCeilingDBFS.isFinite, (-60...0).contains(policy.limiterCeilingDBFS) else { throw ConfigurationError("limiter_ceiling_dbfs must be between -60 and 0.") }
        for (id, input) in inputs.sorted(by: { $0.key < $1.key }) {
            try identifier(id, path: "inputs key")
            try channels(input.channels, path: "inputs.\(id).channels")
            try gain(input.trimDB, path: "inputs.\(id).trim_db")
            switch input.type {
            case "device_input", "virtual_output":
                guard let device = input.device, !device.isEmpty else { throw ConfigurationError("inputs.\(id) requires device.") }
                guard input.application == nil, input.source == nil else { throw ConfigurationError("inputs.\(id) cannot combine device with application or bus source.") }
            case "application_output":
                guard let app = input.application, app.hasPrefix("app:"), app.count > 4 else { throw ConfigurationError("inputs.\(id).application requires a stable app:<bundle-id> identifier.") }
                guard input.device == nil, input.source == nil else { throw ConfigurationError("inputs.\(id) cannot combine application with device or bus source.") }
            case "bus":
                guard let source = input.source, let output = outputs[source], output.type == "bus" else { throw ConfigurationError("inputs.\(id).source must name a bus output in this scenario.") }
                guard input.channels.allSatisfy({ $0 <= output.channels.channelCount }) else { throw ConfigurationError("inputs.\(id) selects a channel outside bus \(source).") }
                guard input.device == nil, input.application == nil else { throw ConfigurationError("Bus inputs cannot also specify a device or application.") }
            default: throw ConfigurationError("Unknown input type '\(input.type)' for \(id).")
            }
            guard input.type == "application_output" || !input.muteOriginal else { throw ConfigurationError("mute_original only applies to application_output.") }
        }
        var destinations = Set<String>()
        for (id, output) in outputs.sorted(by: { $0.key < $1.key }) {
            try identifier(id, path: "outputs key")
            try channels(output.channels.channelIndices, path: "outputs.\(id).channels")
            try gain(output.masterGainDB, path: "outputs.\(id).master_gain_db")
            guard output.device == nil || output.virtualDevice == nil else { throw ConfigurationError("outputs.\(id) must select one of device or virtual_device, not both.") }
            switch output.type {
            case "device_output":
                guard let device = output.device, !device.isEmpty else { throw ConfigurationError("outputs.\(id) requires device.") }
            case "virtual_input", "virtual_output", "bus": break
            default: throw ConfigurationError("Unknown output type '\(output.type)' for \(id).")
            }
            if let app = output.consumerApplication, !app.hasPrefix("app:") || app.count <= 4 { throw ConfigurationError("outputs.\(id).consumer_application must use app:<bundle-id>.") }
            if output.type == "virtual_input" {
                let endpoint = output.virtualDevice ?? output.device ?? id
                guard !endpoint.isEmpty else { throw ConfigurationError("Virtual device identity cannot be empty.") }
                guard destinations.insert(endpoint).inserted else { throw ConfigurationError("Two outputs target virtual input \(endpoint); combine their mixes in one output.") }
            }
            guard !output.mix.isEmpty else { throw ConfigurationError("outputs.\(id).mix requires at least one input.") }
            for (inputID, route) in output.mix.sorted(by: { $0.key < $1.key }) {
                guard let input = inputs[inputID] else { throw ConfigurationError("outputs.\(id).mix references unknown input \(inputID).") }
                try gain(route.gainDB, path: "outputs.\(id).mix.\(inputID).gain_db")
                if route.map != nil || (!route.mute && !input.mute && !output.mute) {
                    _ = try route.weights(sourceChannels: input.channels.count, destinationChannels: output.channels.channelCount)
                }
            }
        }
        if !policy.allowFeedback { try validateFeedback() }
    }

    private func validateFeedback() throws {
        var edges: [String: [String]] = [:]
        for (outputID, output) in outputs where !output.mute {
            for (inputID, route) in output.mix where !route.mute && !(inputs[inputID]?.mute ?? true) {
                edges["input:\(inputID)", default: []].append("output:\(outputID)")
            }
            for (inputID, input) in inputs where !input.mute {
                let sameBus = input.type == "bus" && input.source == outputID
                let endpoint = output.virtualDevice ?? output.device ?? (output.type == "virtual_input" ? (output.name ?? outputID) : nil)
                func canonicalEndpoint(_ value: String) -> String {
                    var result = value
                    for prefix in ["coreaudio:device:", "org.audioroute.virtual.", "virtual:"] where result.hasPrefix(prefix) { result = String(result.dropFirst(prefix.count)) }
                    return result.lowercased().unicodeScalars.map { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0) ? String($0) : "-" }.joined().split(separator: "-").joined(separator: "-")
                }
                // A physical duplex device's input and output are separate ports.
                // A graph cycle exists only when a virtual output is fed back.
                let sameEndpoint = input.type == "virtual_output" && ["virtual_input", "virtual_output"].contains(output.type)
                    && endpoint != nil && input.device.map(canonicalEndpoint) == endpoint.map(canonicalEndpoint)
                let appLoop = output.type == "virtual_input" && output.consumerApplication != nil && input.application == output.consumerApplication
                if sameBus || sameEndpoint || appLoop { edges["output:\(outputID)", default: []].append("input:\(inputID)") }
            }
        }
        var visiting = Set<String>(), visited = Set<String>()
        func visit(_ node: String, path: [String]) throws {
            if visiting.contains(node) { throw ConfigurationError("E_GRAPH_FEEDBACK", "Feedback cycle: \((path + [node]).joined(separator: " -> ")). Mute a return route or explicitly set policy.allow_feedback.") }
            if visited.contains(node) { return }
            visiting.insert(node)
            for next in (edges[node] ?? []).sorted() { try visit(next, path: path + [node]) }
            visiting.remove(node); visited.insert(node)
        }
        for node in edges.keys.sorted() { try visit(node, path: []) }
    }

    private func identifier(_ value: String, path: String) throws {
        guard value.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$", options: .regularExpression) != nil else { throw ConfigurationError("\(path) must be 1–128 letters, digits, underscores, or hyphens, beginning with a letter or digit.") }
    }
    private func gain(_ value: Double, path: String) throws {
        guard value.isFinite, (-120...60).contains(value) else { throw ConfigurationError("\(path) must be finite and between -120 and +60 dB.") }
    }
    private func channels(_ value: [Int], path: String) throws {
        guard !value.isEmpty, value.count <= 64, value.allSatisfy({ (1...64).contains($0) }), Set(value).count == value.count else { throw ConfigurationError("\(path) must contain 1–64 unique, one-based channels between 1 and 64.") }
    }

    static func validateKeys(_ object: Any) throws {
        func check(_ value: Any, allowed: Set<String>, path: String) throws -> [String: Any] {
            guard let mapping = value as? [String: Any] else { throw ConfigurationError("\(path) must be a mapping.") }
            if let key = mapping.keys.filter({ !allowed.contains($0) }).sorted().first { throw ConfigurationError("Unknown configuration key '\(path).\(key)'.") }
            return mapping
        }
        let root = try check(object, allowed: ["version", "scenario", "inputs", "outputs", "policy"], path: "scenario file")
        if let metadata = root["scenario"] { _ = try check(metadata, allowed: ["id", "name", "target_sample_rate", "latency_mode"], path: "scenario") }
        if let value = root["inputs"] {
            guard let mapping = value as? [String: Any] else { throw ConfigurationError("inputs must be a mapping.") }
            for (id, input) in mapping { _ = try check(input, allowed: ["type", "device", "application", "source", "channels", "trim_db", "mute_original", "mute"], path: "inputs.\(id)") }
        }
        if let value = root["outputs"] {
            guard let mapping = value as? [String: Any] else { throw ConfigurationError("outputs must be a mapping.") }
            for (id, output) in mapping {
                let fields = try check(output, allowed: ["name", "type", "device", "virtual_device", "consumer_application", "channels", "master_gain_db", "mute", "mix"], path: "outputs.\(id)")
                if let value = fields["mix"] {
                    guard let mix = value as? [String: Any] else { throw ConfigurationError("outputs.\(id).mix must be a mapping.") }
                    for (source, route) in mix { _ = try check(route, allowed: ["gain_db", "mute", "map"], path: "outputs.\(id).mix.\(source)") }
                }
            }
        }
        if let policy = root["policy"] { _ = try check(policy, allowed: ["reconnect", "disconnected_input", "disconnected_output", "clip_protection", "limiter_ceiling_dbfs", "allow_feedback"], path: "policy") }
    }
}
