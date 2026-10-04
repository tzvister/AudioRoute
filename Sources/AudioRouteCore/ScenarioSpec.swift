import Foundation

public struct ConfigurationError: Error, LocalizedError, Codable, Equatable {
    public let code: String
    public let message: String
    public init(_ message: String) { self.code = "E_CONFIG_INVALID"; self.message = message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public enum ChannelSelection: Codable, Equatable {
    case count(Int)
    case indices([Int])
    public var channelCount: Int { switch self { case .count(let n): return n; case .indices(let a): return a.count } }
    public var channelIndices: [Int] { switch self { case .count(let n): return n > 0 && n <= 64 ? Array(1...n) : []; case .indices(let a): return a } }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .count(n) } else { self = .indices(try c.decode([Int].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .count(let n): try c.encode(n); case .indices(let a): try c.encode(a) }
    }
}

/// A matrix has destination rows and source columns. Channel numbers elsewhere are one-based.
public enum ChannelMap: Codable, Equatable {
    case named(String)
    case matrix([[Double]])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .named(s) } else { self = .matrix(try c.decode([[Double]].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .named(let s): try c.encode(s); case .matrix(let m): try c.encode(m) }
    }
    public func weights(sourceChannels: Int, destinationChannels: Int) throws -> [[Double]] {
        guard sourceChannels > 0, destinationChannels > 0 else { throw ConfigurationError("Channel counts must be positive.") }
        switch self {
        case .matrix(let m):
            guard m.count == destinationChannels, m.allSatisfy({ $0.count == sourceChannels && $0.allSatisfy({ $0.isFinite && Float($0).isFinite }) }) else {
                throw ConfigurationError("Channel matrix must have \(destinationChannels) destination rows and \(sourceChannels) source columns with finite Float32 weights.")
            }
            return m
        case .named(let name):
            var m = Array(repeating: Array(repeating: 0.0, count: sourceChannels), count: destinationChannels)
            switch name {
            case "mono_to_stereo":
                guard sourceChannels == 1, destinationChannels == 2 else { throw ConfigurationError("mono_to_stereo requires one source and two destination channels.") }
                m[0][0] = 1; m[1][0] = 1
            case "stereo_to_mono":
                guard sourceChannels == 2, destinationChannels == 1 else { throw ConfigurationError("stereo_to_mono requires two source and one destination channel.") }
                m[0] = [0.5, 0.5]
            case "stereo":
                guard sourceChannels == 2, destinationChannels == 2 else { throw ConfigurationError("stereo requires two source and two destination channels.") }
                m[0][0] = 1; m[1][1] = 1
            case "identity", "direct":
                guard sourceChannels == destinationChannels else { throw ConfigurationError("identity mapping requires equal channel counts.") }
                for i in 0..<sourceChannels { m[i][i] = 1 }
            default: throw ConfigurationError("Unknown channel map '\(name)'.")
            }
            return m
        }
    }
}

public struct ScenarioMetadata: Codable, Equatable {
    public var id: String
    public var name: String
    public var targetSampleRate: Double
    public var latencyMode: String
    enum CodingKeys: String, CodingKey { case id, name; case targetSampleRate = "target_sample_rate"; case latencyMode = "latency_mode" }
    public init(id: String, name: String? = nil, targetSampleRate: Double = 48000, latencyMode: String = "low") {
        self.id = id; self.name = name ?? id; self.targetSampleRate = targetSampleRate; self.latencyMode = latencyMode
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        targetSampleRate = try c.decodeIfPresent(Double.self, forKey: .targetSampleRate) ?? 48000
        latencyMode = try c.decodeIfPresent(String.self, forKey: .latencyMode) ?? "low"
    }
}

public struct InputSpec: Codable, Equatable {
    public var type: String
    public var device: String?
    public var application: String?
    public var source: String?
    public var channels: [Int]
    public var trimDB: Double
    public var muteOriginal: Bool
    public var mute: Bool
    enum CodingKeys: String, CodingKey { case type, device, application, source, channels, mute; case trimDB = "trim_db"; case muteOriginal = "mute_original" }
    public init(type: String, device: String? = nil, application: String? = nil, source: String? = nil, channels: [Int] = [1, 2], trimDB: Double = 0, muteOriginal: Bool = false, mute: Bool = false) {
        self.type = type; self.device = device; self.application = application; self.source = source; self.channels = channels; self.trimDB = trimDB; self.muteOriginal = muteOriginal; self.mute = mute
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type); device = try c.decodeIfPresent(String.self, forKey: .device)
        application = try c.decodeIfPresent(String.self, forKey: .application); source = try c.decodeIfPresent(String.self, forKey: .source)
        channels = try c.decodeIfPresent([Int].self, forKey: .channels) ?? [1, 2]
        trimDB = try c.decodeIfPresent(Double.self, forKey: .trimDB) ?? 0
        muteOriginal = try c.decodeIfPresent(Bool.self, forKey: .muteOriginal) ?? false; mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
    }
}

public struct MixSpec: Codable, Equatable {
    public var gainDB: Double
    public var mute: Bool
    public var map: ChannelMap?
    enum CodingKeys: String, CodingKey { case mute, map; case gainDB = "gain_db" }
    public init(gainDB: Double = 0, mute: Bool = false, map: ChannelMap? = nil) { self.gainDB = gainDB; self.mute = mute; self.map = map }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0; mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        map = try c.decodeIfPresent(ChannelMap.self, forKey: .map)
    }
    public func weights(sourceChannels: Int, destinationChannels: Int) throws -> [[Double]] {
        if let map { return try map.weights(sourceChannels: sourceChannels, destinationChannels: destinationChannels) }
        let name = sourceChannels == 1 && destinationChannels == 2 ? "mono_to_stereo" : "identity"
        return try ChannelMap.named(name).weights(sourceChannels: sourceChannels, destinationChannels: destinationChannels)
    }
}

public struct OutputSpec: Codable, Equatable {
    public var name: String?
    public var type: String
    public var device: String?
    public var virtualDevice: String?
    public var consumerApplication: String?
    public var channels: ChannelSelection
    public var masterGainDB: Double
    public var mute: Bool
    public var mix: [String: MixSpec]
    enum CodingKeys: String, CodingKey { case name, type, device, channels, mute, mix; case virtualDevice = "virtual_device"; case consumerApplication = "consumer_application"; case masterGainDB = "master_gain_db" }
    public init(type: String, name: String? = nil, device: String? = nil, virtualDevice: String? = nil, consumerApplication: String? = nil, channels: ChannelSelection = .count(2), masterGainDB: Double = 0, mute: Bool = false, mix: [String: MixSpec] = [:]) {
        self.type = type; self.name = name; self.device = device; self.virtualDevice = virtualDevice; self.consumerApplication = consumerApplication; self.channels = channels; self.masterGainDB = masterGainDB; self.mute = mute; self.mix = mix
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name); type = try c.decode(String.self, forKey: .type)
        device = try c.decodeIfPresent(String.self, forKey: .device); virtualDevice = try c.decodeIfPresent(String.self, forKey: .virtualDevice)
        consumerApplication = try c.decodeIfPresent(String.self, forKey: .consumerApplication)
        channels = try c.decodeIfPresent(ChannelSelection.self, forKey: .channels) ?? .count(2)
        masterGainDB = try c.decodeIfPresent(Double.self, forKey: .masterGainDB) ?? 0; mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
        mix = try c.decode([String: MixSpec].self, forKey: .mix)
    }
}

public struct PolicySpec: Codable, Equatable {
    public var reconnect: Bool
    public var disconnectedInput: String
    public var disconnectedOutput: String
    public var clipProtection: Bool
    public var limiterCeilingDBFS: Double
    public var allowFeedback: Bool
    enum CodingKeys: String, CodingKey { case reconnect; case disconnectedInput = "disconnected_input"; case disconnectedOutput = "disconnected_output"; case clipProtection = "clip_protection"; case limiterCeilingDBFS = "limiter_ceiling_dbfs"; case allowFeedback = "allow_feedback" }
    public init(reconnect: Bool = true, disconnectedInput: String = "silence", disconnectedOutput: String = "discard", clipProtection: Bool = true, limiterCeilingDBFS: Double = -1, allowFeedback: Bool = false) {
        self.reconnect = reconnect; self.disconnectedInput = disconnectedInput; self.disconnectedOutput = disconnectedOutput
        self.clipProtection = clipProtection; self.limiterCeilingDBFS = limiterCeilingDBFS; self.allowFeedback = allowFeedback
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reconnect = try c.decodeIfPresent(Bool.self, forKey: .reconnect) ?? true
        disconnectedInput = try c.decodeIfPresent(String.self, forKey: .disconnectedInput) ?? "silence"
        disconnectedOutput = try c.decodeIfPresent(String.self, forKey: .disconnectedOutput) ?? "discard"
        clipProtection = try c.decodeIfPresent(Bool.self, forKey: .clipProtection) ?? true
        limiterCeilingDBFS = try c.decodeIfPresent(Double.self, forKey: .limiterCeilingDBFS) ?? -1
        allowFeedback = try c.decodeIfPresent(Bool.self, forKey: .allowFeedback) ?? false
    }
}

public struct ScenarioSpec: Codable, Equatable {
    public var version: Int
    public var scenario: ScenarioMetadata
    public var inputs: [String: InputSpec]
    public var outputs: [String: OutputSpec]
    public var policy: PolicySpec
    enum CodingKeys: String, CodingKey { case version, scenario, inputs, outputs, policy }
    public init(version: Int = 1, scenario: ScenarioMetadata, inputs: [String: InputSpec], outputs: [String: OutputSpec], policy: PolicySpec = PolicySpec()) {
        self.version = version; self.scenario = scenario; self.inputs = inputs; self.outputs = outputs; self.policy = policy
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); scenario = try c.decode(ScenarioMetadata.self, forKey: .scenario)
        inputs = try c.decode([String: InputSpec].self, forKey: .inputs); outputs = try c.decode([String: OutputSpec].self, forKey: .outputs)
        policy = try c.decodeIfPresent(PolicySpec.self, forKey: .policy) ?? PolicySpec()
    }
    public static func load(data: Data) throws -> ScenarioSpec {
        guard data.count <= 1_048_576 else { throw ConfigurationError("Configuration exceeds the 1 MiB size limit.") }
        do {
            let object: Any
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { object = json }
            else {
                guard let text = String(data: data, encoding: .utf8) else { throw ConfigurationError("Configuration must be UTF-8.") }
                object = try RestrictedYAML.parse(text)
            }
            try validateKeys(object)
            let json = try JSONSerialization.data(withJSONObject: object)
            let spec = try JSONDecoder().decode(ScenarioSpec.self, from: json)
            try spec.validate()
            return spec
        } catch let error as ConfigurationError { throw error }
        catch { throw ConfigurationError("Cannot decode scenario: \(error.localizedDescription)") }
    }
    public func jsonData(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return try encoder.encode(self)
    }
}
