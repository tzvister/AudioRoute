import XCTest
@testable import AudioRouteControl
import AudioRouteCore
import Darwin

final class ControlTests: XCTestCase {
    func testWireRoundTripAndVersionRejection() throws {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        try Wire.send(["protocol_version": 1, "message": "hello\nworld"], to: sockets[0])
        let received = try Wire.receive(from: sockets[1])
        XCTAssertEqual(received["message"] as? String, "hello\nworld")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try RouterService(stateURL: directory.appendingPathComponent("state.json"))
        let response = service.handle(["protocol_version": 99, "command": "ping"])
        XCTAssertEqual(response["ok"] as? Bool, false)
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? String, "E_PROTOCOL_VERSION")
    }
    func testPersistenceFailureKeepsPreviousScenario() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let service = try RouterService(stateURL: url)
        let spec = ScenarioSpec(scenario: .init(id: "rollback"), inputs: ["in": .init(type: "device_input", device: "coreaudio:device:absent", channels: [1])], outputs: ["out": .init(type: "device_output", device: "coreaudio:device:absent-out", mix: ["in": .init()])])
        let applied = service.handle(["protocol_version": 1, "command": "scenario.apply", "arguments": ["spec": String(data: try spec.jsonData(), encoding: .utf8)!]])
        XCTAssertEqual(applied["ok"] as? Bool, true)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let failed = service.handle(["protocol_version": 1, "command": "level.set", "arguments": ["id": "rollback", "output": "out", "master_db": 6.0]])
        XCTAssertEqual(failed["ok"] as? Bool, false)
        let shown = service.handle(["protocol_version": 1, "command": "scenario.show", "arguments": ["id": "rollback"]])
        let restored = try JSONDecoder().decode(ScenarioSpec.self, from: JSONSerialization.data(withJSONObject: shown["result"]!))
        XCTAssertEqual(restored, spec)
        XCTAssertEqual(service.engine.status(id: "rollback")["state"] as? String, "degraded")
    }
    func testSocketPathBounds() {
        XCTAssertThrowsError(try Wire.address(String(repeating: "x", count: 200)))
        XCTAssertNoThrow(try Wire.address("/tmp/ar-test.sock"))
    }
    func testApplyIdempotencyIndependentLevelsRollbackAndPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let service = try RouterService(stateURL: url)
        let spec = ScenarioSpec(scenario: .init(id: "test"), inputs: ["guitar": .init(type: "device_input", device: "coreaudio:device:nonexistent-test-input", channels: [1])], outputs: [
            "teacher": .init(type: "device_output", device: "coreaudio:device:nonexistent-test-output", mix: ["guitar": .init(gainDB: -3)]),
            "listener": .init(type: "device_output", device: "coreaudio:device:nonexistent-test-output-2", masterGainDB: 2, mix: ["guitar": .init(gainDB: 3)])])
        let text = String(data: try spec.jsonData(), encoding: .utf8)!
        func call(_ command: String, _ args: [String: Any] = [:]) -> [String: Any] { service.handle(["protocol_version": 1, "command": command, "arguments": args]) }
        XCTAssertEqual(call("scenario.apply", ["spec": text, "dry_run": true])["ok"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let applied = call("scenario.apply", ["spec": text])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")
        XCTAssertEqual((call("scenario.apply", ["spec": text])["result"] as? [String: Any])?["changed"] as? Bool, false)
        XCTAssertEqual(call("level.set", ["id": "test", "output": "teacher", "input": "guitar", "db": -9.0])["ok"] as? Bool, true)
        let stored = try JSONDecoder().decode([String: ScenarioSpec].self, from: Data(contentsOf: url))["test"]!
        XCTAssertEqual(stored.outputs["teacher"]?.mix["guitar"]?.gainDB, -9)
        XCTAssertEqual(stored.outputs["listener"]?.mix["guitar"]?.gainDB, 3)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(call("scenario.apply", ["spec": "version: 999"])["ok"] as? Bool, false)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(call("scenario.delete", ["id": "test"])["ok"] as? Bool, false)
        let restored = try RouterService(stateURL: url)
        let listed = restored.handle(["protocol_version": 1, "command": "scenario.list"])
        XCTAssertEqual(listed["result"] as? [String], ["test"])
        XCTAssertEqual(call("scenario.delete", ["id": "test", "yes": true])["ok"] as? Bool, true)
    }
}
