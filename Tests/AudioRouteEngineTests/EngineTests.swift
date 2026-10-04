import XCTest
import AudioRouteEngine
import AudioRouteCore
import CAudioRT

final class EngineTests: XCTestCase {
    func testRealtimeIndependentMixesPositiveGainAndChannelMaps() throws {
        let source = try XCTUnwrap(ar_source_create(2, nil, 48000))
        let first = try XCTUnwrap(ar_sink_create(2, nil, 48000, 0))
        let second = try XCTUnwrap(ar_sink_create(2, nil, 48000, 0))
        defer { ar_sink_destroy(first); ar_sink_destroy(second); ar_source_destroy(source) }
        let unity: [Float] = [1, 0, 0, 1], boostedSwap: [Float] = [0, 2, 0.5, 0]
        XCTAssertTrue(unity.withUnsafeBufferPointer { ar_sink_add_route(first, source, $0.baseAddress) })
        XCTAssertTrue(boostedSwap.withUnsafeBufferPointer { ar_sink_add_route(second, source, $0.baseAddress) })
        let audio = (0..<1024).flatMap { _ in [Float(0.25), Float(0.75)] }
        audio.withUnsafeBufferPointer { for _ in 0..<3 { ar_source_push(source, $0.baseAddress, 1024) } }
        var output = [Float](repeating: 0, count: 512)
        output.withUnsafeMutableBufferPointer { ar_sink_render(first, $0.baseAddress, 256) }
        XCTAssertEqual(output[0], 0.25, accuracy: 0.00001); XCTAssertEqual(output[1], 0.75, accuracy: 0.00001)
        output.withUnsafeMutableBufferPointer { ar_sink_render(second, $0.baseAddress, 256) }
        XCTAssertEqual(output[0], 1.5, accuracy: 0.00001); XCTAssertEqual(output[1], 0.125, accuracy: 0.00001)
        XCTAssertEqual(ar_sink_stats(second).clipped_samples, 256)
        XCTAssertEqual(ar_sink_stats(first).clipped_samples, 0)
        // Pulling the first sink again does not change the second sink's reader.
        output.withUnsafeMutableBufferPointer { ar_sink_render(first, $0.baseAddress, 256) }
        XCTAssertEqual(output[0], 0.25, accuracy: 0.00001)
    }
    func testRealtimeSummingAndExplicitClippingProtection() throws {
        let one = try XCTUnwrap(ar_source_create(1, nil, 48000)), two = try XCTUnwrap(ar_source_create(1, nil, 44100))
        let sink = try XCTUnwrap(ar_sink_create(1, nil, 48000, 0.8))
        defer { ar_sink_destroy(sink); ar_source_destroy(one); ar_source_destroy(two) }
        var matrix: Float = 1
        XCTAssertTrue(ar_sink_add_route(sink, one, &matrix)); XCTAssertTrue(ar_sink_add_route(sink, two, &matrix))
        let audio = [Float](repeating: 0.75, count: 1024)
        audio.withUnsafeBufferPointer { for _ in 0..<3 { ar_source_push(one, $0.baseAddress, 1024); ar_source_push(two, $0.baseAddress, 1024) } }
        var output = [Float](repeating: 0, count: 256)
        output.withUnsafeMutableBufferPointer { ar_sink_render(sink, $0.baseAddress, 256) }
        XCTAssertTrue(output.allSatisfy { abs($0 - 0.8) < 0.00001 })
        XCTAssertEqual(ar_sink_stats(sink).peak, 1.5, accuracy: 0.00001)
        XCTAssertEqual(ar_sink_stats(sink).clipped_samples, 256)
    }
    func testRealtimeOverflowAndUnderflowAreCounted() throws {
        let source = try XCTUnwrap(ar_source_create(1, nil, 48000)), sink = try XCTUnwrap(ar_sink_create(1, nil, 48000, 0))
        defer { ar_sink_destroy(sink); ar_source_destroy(source) }
        var matrix: Float = 1; XCTAssertTrue(ar_sink_add_route(sink, source, &matrix))
        let audio = [Float](repeating: 0.5, count: 20000)
        audio.withUnsafeBufferPointer { ar_source_push(source, $0.baseAddress, 20000) }
        XCTAssertEqual(ar_source_stats(source).overruns, 1)
        var output = [Float](repeating: 0, count: 1024)
        for _ in 0..<20 { output.withUnsafeMutableBufferPointer { ar_sink_render(sink, $0.baseAddress, 1024) } }
        XCTAssertGreaterThan(ar_sink_stats(sink).underruns, 0)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }
    func testNonfinitePCMIsSilencedAndReported() throws {
        let source = try XCTUnwrap(ar_source_create(1, nil, 48000)), sink = try XCTUnwrap(ar_sink_create(1, nil, 48000, 0))
        defer { ar_sink_destroy(sink); ar_source_destroy(source) }
        var bad: Float = .infinity
        XCTAssertFalse(ar_sink_add_route(sink, source, &bad))
        var good: Float = 1
        XCTAssertTrue(ar_sink_add_route(sink, source, &good))
        let audio = [Float](repeating: .nan, count: 1024)
        audio.withUnsafeBufferPointer { for _ in 0..<3 { ar_source_push(source, $0.baseAddress, 1024) } }
        var output = [Float](repeating: 1, count: 256)
        output.withUnsafeMutableBufferPointer { ar_sink_render(sink, $0.baseAddress, 256) }
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
        XCTAssertEqual(ar_source_stats(source).invalid_samples, 3072)
        XCTAssertEqual(ar_source_stats(source).peak, 0)
    }
    func testPreflightIsSideEffectFreeAndFailedApplyRetainsPreviousGraph() throws {
        let spec = ScenarioSpec(scenario: ScenarioMetadata(id: "preflight-test", name: "Preflight test"), inputs: ["missing": InputSpec(type: "device_input", device: "coreaudio:device:nonexistent-engine-test", channels: [1])], outputs: ["discard": OutputSpec(type: "device_output", device: "coreaudio:device:nonexistent-output-engine-test", channels: .count(1), mix: ["missing": MixSpec()])])
        let engine = Engine()
        XCTAssertEqual(try engine.preflight(spec)["side_effects"] as? Bool, false)
        XCTAssertEqual(engine.status(id: spec.scenario.id)["state"] as? String, "stopped")
        try engine.apply(spec); defer { engine.remove(id: spec.scenario.id) }
        var invalid = spec; invalid.outputs["discard"]?.masterGainDB = 100
        XCTAssertThrowsError(try engine.apply(invalid))
        XCTAssertEqual(engine.status(id: spec.scenario.id)["state"] as? String, "degraded")
        var changed = spec; changed.outputs["discard"]?.masterGainDB = 6
        XCTAssertThrowsError(try engine.apply(changed) { throw EngineError("E_TEST_PERSIST", "Persistence failed") })
        let outputs = engine.status(id: spec.scenario.id)["outputs"] as? [String: [String: Any]]
        XCTAssertEqual(outputs?["discard"]?["master_gain_db"] as? Double, 0)
    }
    func testRealCoreAudioDiscoveryAndTruthfulStoppedState() {
        let engine = Engine()
        for device in engine.devices() {
            XCTAssertGreaterThan(device["object_id"] as? UInt32 ?? 0, 0)
            XCTAssertFalse((device["uid"] as? String ?? "").isEmpty)
            XCTAssertTrue((device["id"] as? String ?? "").hasPrefix("coreaudio:device:"))
        }
        XCTAssertEqual(engine.status(id: "absent")["working"] as? Bool, false)
        XCTAssertEqual(engine.permissions()["system_audio_preflight_available"] as? Bool, false)
    }
    func testMissingEndpointsRemainDegradedAndNeverVerified() throws {
        let spec = ScenarioSpec(scenario: ScenarioMetadata(id: "engine-test", name: "Engine test"), inputs: ["missing": InputSpec(type: "device_input", device: "coreaudio:device:nonexistent-engine-test", channels: [1])], outputs: ["discard": OutputSpec(type: "device_output", device: "coreaudio:device:nonexistent-output-engine-test", channels: .count(1), mix: ["missing": MixSpec()])])
        let engine = Engine(); try engine.apply(spec)
        defer { engine.remove(id: "engine-test") }
        let status = engine.status(id: "engine-test")
        XCTAssertEqual(status["state"] as? String, "degraded"); XCTAssertEqual(status["working"] as? Bool, false)
        try engine.apply(spec) // idempotent apply does not recreate graph
        engine.reconcile()
        XCTAssertEqual(engine.status(id: "engine-test")["recent_reconnects"] as? Int, 0)
    }
}
