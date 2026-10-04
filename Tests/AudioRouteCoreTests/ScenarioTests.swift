import XCTest
@testable import AudioRouteCore

final class ScenarioTests: XCTestCase {
    private let lesson = """
    version: 1
    scenario:
      id: guitar-lesson
      name: Guitar Lesson
      target_sample_rate: 48000
      latency_mode: low
    inputs:
      guitar:
        type: device_input
        device: coreaudio:device:GUITAR_UID
        channels: [1]
        trim_db: -2
      voice:
        type: device_input
        device: coreaudio:device:MIC_UID
        channels: [1]
      teacher:
        type: application_output
        application: app:us.zoom.xos
        channels: [1, 2]
        mute_original: true
    outputs:
      teacher-send:
        type: virtual_input
        name: Guitar Lesson Send
        consumer_application: app:us.zoom.xos
        channels: 2
        mix:
          guitar: {gain_db: -3, map: mono_to_stereo}
          voice: {gain_db: 0, map: mono_to_stereo}
          teacher: {mute: true}
      airpods:
        type: device_output
        device: coreaudio:device:AIRPODS_UID
        channels: [1, 2]
        master_gain_db: 2
        mix:
          guitar: {gain_db: 3, map: mono_to_stereo}
          voice: {mute: true}
          teacher: {gain_db: -6, map: stereo}
    policy:
      reconnect: true
      disconnected_input: silence
      disconnected_output: discard
      clip_protection: false
    """

    private func load(_ text: String) throws -> ScenarioSpec { try ScenarioSpec.load(data: Data(text.utf8)) }

    func testFullBriefScenarioYAMLAndJSONRoundTrip() throws {
        let spec = try load(lesson)
        XCTAssertEqual(spec.scenario.id, "guitar-lesson")
        XCTAssertEqual(spec.inputs["teacher"]?.application, "app:us.zoom.xos")
        XCTAssertEqual(spec.outputs["airpods"]?.channels, .indices([1, 2]))
        XCTAssertEqual(spec.outputs["teacher-send"]?.channels, .count(2))
        XCTAssertEqual(spec.outputs["airpods"]?.masterGainDB, 2)
        XCTAssertEqual(try ScenarioSpec.load(data: spec.jsonData()), spec)
        let json = String(decoding: try spec.jsonData(), as: UTF8.self)
        XCTAssertTrue(json.contains("master_gain_db")); XCTAssertFalse(json.contains("masterGainDB"))
    }

    func testIndependentDestinationGainTrimAndMute() throws {
        var spec = try load(lesson)
        let sources: [String: [[Float]]] = ["guitar": [[0.1, -0.1]], "voice": [[0.2, 0.2]], "teacher": [[0.3, 0.3], [0.4, 0.4]]]
        let old = try OfflineMixer.render(spec, sources: sources)
        let guitarToTeacher = 0.1 * pow(10, -5.0 / 20)
        XCTAssertEqual(Double(old["teacher-send"]!.samples[0][0]), guitarToTeacher + 0.2, accuracy: 0.000001)
        XCTAssertEqual(old["teacher-send"]!.samples[0], old["teacher-send"]!.samples[1])
        let guitarToAirpods = 0.1 * pow(10, 3.0 / 20) // -2 trim +3 route +2 master
        let teacherToAirpods = 0.3 * pow(10, -4.0 / 20)
        XCTAssertEqual(Double(old["airpods"]!.samples[0][0]), guitarToAirpods + teacherToAirpods, accuracy: 0.000001)
        spec.outputs["teacher-send"]!.mix["guitar"]!.gainDB = -20
        let new = try OfflineMixer.render(spec, sources: sources)
        XCTAssertEqual(old["airpods"], new["airpods"])
        XCTAssertNotEqual(old["teacher-send"], new["teacher-send"])
    }

    func testPositiveOutputGainIsNotCappedAndClippingIsMeasured() throws {
        var spec = try load(lesson)
        spec.outputs = ["boost": OutputSpec(type: "virtual_input", channels: .count(2), masterGainDB: 6, mix: ["guitar": MixSpec()])]
        spec.inputs["guitar"]!.trimDB = 0
        let output = try OfflineMixer.render(spec, sources: ["guitar": [[0.75, -0.75]]])["boost"]!
        XCTAssertEqual(Double(output.samples[0][0]), 0.75 * pow(10, 6 / 20.0), accuracy: 0.000001)
        XCTAssertEqual(output.meters.clippedSamples, 4)
        XCTAssertGreaterThan(output.meters.peakDBFS!, 0)
        spec.policy.clipProtection = true
        let limited = try OfflineMixer.render(spec, sources: ["guitar": [[0.75, -0.75]]])["boost"]!
        XCTAssertEqual(Double(limited.samples[0][0]), pow(10, -1 / 20.0), accuracy: 0.000001)
        XCTAssertEqual(limited.meters.clippedSamples, 4)
    }

    func testMissingInputsContributeSilenceAndSilenceMetersAreJSONSafe() throws {
        let output = try OfflineMixer.render(load(lesson), sources: [:], frameCount: 16)
        XCTAssertTrue(output.values.allSatisfy { $0.meters.silence && $0.samples.allSatisfy { $0 == Array(repeating: 0, count: 16) } })
        let json = try JSONEncoder().encode(output["teacher-send"]!.meters)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: json))
    }

    func testExplicitMatrixAndDownmix() throws {
        var spec = try load(lesson)
        spec.outputs = ["matrix": OutputSpec(type: "virtual_input", channels: .count(2), mix: ["teacher": MixSpec(map: .matrix([[0, 1], [1, 0]]))])]
        let swapped = try OfflineMixer.render(spec, sources: ["teacher": [[0.2], [0.4]]])["matrix"]!
        XCTAssertEqual(swapped.samples, [[0.4], [0.2]])
        spec.outputs["matrix"]!.channels = .count(1)
        spec.outputs["matrix"]!.mix["teacher"]!.map = .named("stereo_to_mono")
        XCTAssertEqual(try OfflineMixer.render(spec, sources: ["teacher": [[0.2], [0.4]]])["matrix"]!.samples[0][0], 0.3, accuracy: 0.000001)
    }

    func testKnownApplicationReturnFeedbackRejectedAndMutedReturnAllowed() throws {
        var spec = try load(lesson)
        spec.outputs["teacher-send"]!.mix["teacher"]!.mute = false
        XCTAssertThrowsError(try spec.validate()) { XCTAssertEqual(($0 as? ConfigurationError)?.code, "E_GRAPH_FEEDBACK") }
        spec.outputs["teacher-send"]!.mix["teacher"]!.mute = true
        XCTAssertNoThrow(try spec.validate())
    }

    func testBusTopologyRenderedAndCycleDetected() throws {
        let inputs = ["guitar": InputSpec(type: "device_input", device: "uid", channels: [1]), "return": InputSpec(type: "bus", source: "sum", channels: [1])]
        var spec = ScenarioSpec(scenario: ScenarioMetadata(id: "bus-test"), inputs: inputs, outputs: [
            "sum": OutputSpec(type: "bus", channels: .count(1), mix: ["guitar": MixSpec()]),
            "send": OutputSpec(type: "virtual_input", channels: .count(1), mix: ["return": MixSpec(gainDB: -6)])
        ], policy: PolicySpec(clipProtection: false))
        let rendered = try OfflineMixer.render(spec, sources: ["guitar": [[0.5]]])
        XCTAssertEqual(Double(rendered["send"]!.samples[0][0]), 0.5 * pow(10, -6 / 20.0), accuracy: 0.000001)
        spec.outputs["sum"]!.mix["return"] = MixSpec()
        XCTAssertThrowsError(try spec.validate()) { XCTAssertEqual(($0 as? ConfigurationError)?.code, "E_GRAPH_FEEDBACK") }
    }

    func testRejectsUnknownKeysReferencesChannelsAndNonfiniteGain() throws {
        XCTAssertThrowsError(try load(lesson.replacingOccurrences(of: "trim_db: -2", with: "trmi_db: -2")))
        var spec = try load(lesson)
        spec.outputs["airpods"]!.mix["ghost"] = MixSpec()
        XCTAssertThrowsError(try spec.validate())
        spec = try load(lesson); spec.inputs["guitar"]!.channels = [0]
        XCTAssertThrowsError(try spec.validate())
        spec = try load(lesson); spec.inputs["guitar"]!.channels = [1, 1]
        XCTAssertThrowsError(try spec.validate())
        spec = try load(lesson); spec.outputs["airpods"]!.masterGainDB = .nan
        XCTAssertThrowsError(try spec.validate())
        spec = try load(lesson); spec.outputs["airpods"]!.channels = .count(Int.max)
        XCTAssertThrowsError(try spec.validate())
    }

    func testRejectsIncorrectMapDimensionsAndUnsafeBuffers() throws {
        var spec = try load(lesson)
        spec.outputs["airpods"]!.mix["guitar"]!.map = .matrix([[1, 1], [1, 1]])
        XCTAssertThrowsError(try spec.validate())
        spec.outputs["airpods"]!.mix["guitar"]!.map = .matrix([[Double.greatestFiniteMagnitude], [1]])
        XCTAssertThrowsError(try spec.validate())
        spec = try load(lesson)
        XCTAssertThrowsError(try OfflineMixer.render(spec, sources: ["guitar": [[Float.nan]]]))
        XCTAssertThrowsError(try OfflineMixer.render(spec, sources: ["guitar": [[1, 2]], "voice": [[3]]]))
        XCTAssertThrowsError(try OfflineMixer.render(spec, sources: [:], frameCount: -1))
    }

    func testYAMLDuplicatesAliasesTagsMalformedFlowsRejected() throws {
        for bad in ["version: 1\nversion: 1", "version: &v 1", "version: *v", "version: !!int 1", "version: [1, 2", "version: [1,,2]", "version: 1\n\tbad: true"] {
            XCTAssertThrowsError(try load(bad), bad)
        }
    }

    func testYAMLQuotesCommentsAndBlockSequences() throws {
        let variant = lesson.replacingOccurrences(of: "name: Guitar Lesson", with: "name: 'Teacher''s #1 lesson' # comment")
            .replacingOccurrences(of: "channels: [1, 2]", with: "channels:\n          - 1\n          - 2")
        XCTAssertEqual(try load(variant).scenario.name, "Teacher's #1 lesson")
        XCTAssertEqual(try load(lesson.replacingOccurrences(of: "name: Guitar Lesson", with: "name: Teacher's guitar # comment")).scenario.name, "Teacher's guitar")
    }

    func testVirtualAliasFeedbackDetectedAndPhysicalDuplexAllowed() throws {
        var spec = ScenarioSpec(scenario: ScenarioMetadata(id: "loop"), inputs: ["return": InputSpec(type: "virtual_output", device: "coreaudio:device:org.audioroute.virtual.loop", channels: [1])], outputs: ["send": OutputSpec(type: "virtual_input", virtualDevice: "virtual:loop", channels: .count(1), mix: ["return": MixSpec()])])
        XCTAssertThrowsError(try spec.validate()) { XCTAssertEqual(($0 as? ConfigurationError)?.code, "E_GRAPH_FEEDBACK") }
        spec.inputs["return"]!.device = "virtual:loop-return"
        spec.outputs["send"]!.virtualDevice = nil
        spec.outputs["send"]!.name = "Loop Return"
        XCTAssertThrowsError(try spec.validate()) { XCTAssertEqual(($0 as? ConfigurationError)?.code, "E_GRAPH_FEEDBACK") }
        spec.inputs["return"] = InputSpec(type: "device_input", device: "duplex-uid", channels: [1])
        spec.outputs["send"] = OutputSpec(type: "device_output", device: "duplex-uid", channels: .count(1), mix: ["return": MixSpec()])
        XCTAssertNoThrow(try spec.validate())
    }

    func testRenderOverflowAndExcessWorkingSetRejected() throws {
        var spec = try load(lesson)
        spec.outputs["airpods"]!.masterGainDB = 60
        XCTAssertThrowsError(try OfflineMixer.render(spec, sources: ["guitar": [[Float.greatestFiniteMagnitude]]]))
        spec.outputs["extra"] = spec.outputs["airpods"]
        XCTAssertThrowsError(try OfflineMixer.render(spec, sources: [:], frameCount: 1_048_576))
    }
}
