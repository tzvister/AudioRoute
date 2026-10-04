import Foundation

public struct AudioMeters: Codable, Equatable {
    public let peak: Double
    public let rms: Double
    /// nil denotes digital silence; JSON never contains an infinite number.
    public let peakDBFS: Double?
    public let rmsDBFS: Double?
    public let clippedSamples: Int
    public let silence: Bool
    enum CodingKeys: String, CodingKey { case peak, rms, silence; case peakDBFS = "peak_dbfs"; case rmsDBFS = "rms_dbfs"; case clippedSamples = "clipped_samples" }
    public init(samples: [[Float]], clippedSamples: Int = 0) {
        var peak = 0.0, sum = 0.0, count = 0
        for channel in samples { for sample in channel { let value = Double(sample); peak = max(peak, abs(value)); sum += value * value; count += 1 } }
        let rms = count == 0 ? 0 : sqrt(sum / Double(count))
        self.peak = peak; self.rms = rms; self.peakDBFS = peak > 0 ? 20 * log10(peak) : nil
        self.rmsDBFS = rms > 0 ? 20 * log10(rms) : nil; self.clippedSamples = clippedSamples; self.silence = peak < 0.000001
    }
}

public struct RenderedOutput: Equatable {
    public let samples: [[Float]]
    public let meters: AudioMeters
}

/// Reference renderer for fixtures and diagnostics. This allocates and must never
/// be called in a Core Audio callback. Live audio uses the preallocated C engine.
public enum OfflineMixer {
    public static func render(_ spec: ScenarioSpec, sources: [String: [[Float]]], frameCount requestedFrames: Int? = nil) throws -> [String: RenderedOutput] {
        try spec.validate()
        let frameCount = requestedFrames ?? sources.values.first?.first?.count ?? 0
        guard (0...1_048_576).contains(frameCount) else { throw ConfigurationError("Offline frame count must be between 0 and 1048576.") }
        let totalChannels = spec.outputs.values.reduce(0) { $0 + $1.channels.channelCount } + spec.inputs.values.reduce(0) { $0 + $1.channels.count }
        guard frameCount * totalChannels <= 8_388_608 else { throw ConfigurationError("Offline render exceeds the 8 million sample working-set limit; render shorter blocks.") }
        for (id, samples) in sources {
            guard let input = spec.inputs[id] else { throw ConfigurationError("Offline samples reference unknown input \(id).") }
            guard input.type != "bus" else { throw ConfigurationError("Bus input samples are generated from their output, not supplied externally.") }
            guard samples.count == input.channels.count, samples.allSatisfy({ $0.count == frameCount && $0.allSatisfy(\.isFinite) }) else {
                throw ConfigurationError("Offline input \(id) must have \(input.channels.count) planar channels of \(frameCount) finite samples each.")
            }
        }
        let silence = Array(repeating: Float(0), count: frameCount)
        var rendered: [String: RenderedOutput] = [:], visiting = Set<String>()
        func renderOutput(_ id: String) throws -> RenderedOutput {
            if let existing = rendered[id] { return existing }
            guard visiting.insert(id).inserted else { throw ConfigurationError("E_GRAPH_FEEDBACK", "Offline renderer cannot render a feedback cycle, even with allow_feedback enabled.") }
            defer { visiting.remove(id) }
            let output = spec.outputs[id]!
            var buffer = Array(repeating: silence, count: output.channels.channelCount)
            if !output.mute {
                for (inputID, route) in output.mix.sorted(by: { $0.key < $1.key }) {
                    let input = spec.inputs[inputID]!
                    if input.mute || route.mute { continue }
                    let samples: [[Float]]
                    if input.type == "bus", let source = input.source {
                        let bus = try renderOutput(source).samples
                        samples = input.channels.map { bus[$0 - 1] }
                    } else { samples = sources[inputID] ?? Array(repeating: silence, count: input.channels.count) }
                    let weights = try route.weights(sourceChannels: input.channels.count, destinationChannels: output.channels.channelCount)
                    let gain = Float(pow(10, (input.trimDB + route.gainDB + output.masterGainDB) / 20))
                    for destination in buffer.indices {
                        for source in samples.indices where weights[destination][source] != 0 {
                            let factor = gain * Float(weights[destination][source])
                            for frame in 0..<frameCount { buffer[destination][frame] += samples[source][frame] * factor }
                        }
                    }
                }
            }
            var clipped = 0
            let ceiling = Float(pow(10, spec.policy.limiterCeilingDBFS / 20))
            for channel in buffer.indices { for frame in buffer[channel].indices {
                let value = buffer[channel][frame]
                guard value.isFinite else { throw ConfigurationError("E_AUDIO_SAMPLE_INVALID", "Mixing overflowed a 32-bit float sample on output \(id). Reduce gain or matrix weights.") }
                if abs(value) > 1 { clipped += 1 }
                if spec.policy.clipProtection { buffer[channel][frame] = min(ceiling, max(-ceiling, value)) }
            } }
            let result = RenderedOutput(samples: buffer, meters: AudioMeters(samples: buffer, clippedSamples: clipped))
            rendered[id] = result
            return result
        }
        for outputID in spec.outputs.keys.sorted() { _ = try renderOutput(outputID) }
        return rendered
    }
}
