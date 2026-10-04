import Foundation
import Darwin
import VirtualAudioTransport

public enum VirtualRegistry {
    public static let root = URL(fileURLWithPath: AR_SHARED_DIRECTORY)
    public static var registryURL: URL { root.appendingPathComponent("registry.plist") }
    public static func list() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return [] }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: registryURL), format: nil) as? [String: Any]
        guard let devices = plist?["devices"] as? [[String: Any]] else { throw ControlError("E_REGISTRY_INVALID", "Invalid virtual device registry") }
        return devices
    }
    public static func create(name: String, input: Int, output: Int, dryRun: Bool) throws -> [String: Any] {
        guard !name.isEmpty, name.utf8.count <= 128, (0...32).contains(input), (0...32).contains(output), input + output > 0 else { throw ControlError("E_USAGE", "Virtual device needs a name and 1...32 channels in at least one direction") }
        let id = name.lowercased().unicodeScalars.map { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0) ? String($0) : "-" }.joined().split(separator: "-").joined(separator: "-")
        guard !id.isEmpty, id.count <= 80 else { throw ControlError("E_USAGE", "Name must contain letters/numbers and produce an ID no longer than 80 characters") }
        var devices = try list()
        if let existing = devices.first(where: { $0["id"] as? String == id }) {
            guard existing["name"] as? String == name, existing["inputChannels"] as? Int == input, existing["outputChannels"] as? Int == output else { throw ControlError("E_VIRTUAL_CONFLICT", "Device ID already exists with a different name or channel layout") }
            return ["changed": false, "device": existing]
        }
        guard devices.count < 128 else { throw ControlError("E_RESOURCE_LIMIT", "The driver supports up to 128 virtual device identities per Core Audio session") }
        let device: [String: Any] = ["id": id, "name": name, "inputChannels": input, "outputChannels": output, "sampleRate": 48000, "uid": "org.audioroute.virtual.\(id)"]
        if dryRun { return ["changed": false, "would_create": device] }
        guard FileManager.default.isWritableFile(atPath: root.path) else { throw ControlError("E_DRIVER_NOT_INSTALLED", "Install the AudioRoute HAL driver with scripts/install-driver.sh. The shared registry directory is unavailable.") }
        let path = root.appendingPathComponent("devices/\(id).shm").path
        guard let transport = ar_transport_open(path, UInt32(input), UInt32(output), 1) else { throw ControlError("E_VIRTUAL_TRANSPORT", "Cannot initialize shared audio transport: \(String(cString: strerror(errno)))") }
        ar_transport_close(transport)
        devices.append(device)
        try save(devices)
        return ["changed": true, "device": device, "publication": "pending_hal_discovery"]
    }
    public static func delete(id: String, yes: Bool, dryRun: Bool) throws -> [String: Any] {
        guard yes else { throw ControlError("E_CONFIRMATION_REQUIRED", "Pass --yes to delete a virtual device") }
        var devices = try list()
        guard devices.contains(where: { $0["id"] as? String == id }) else { throw ControlError("E_DEVICE_NOT_FOUND", "Unknown virtual device") }
        if dryRun { return ["changed": false, "would_delete": id] }
        devices.removeAll { $0["id"] as? String == id }
        try save(devices)
        // Keep backing inode until all HAL clients release it; reuse preserves mappings safely.
        return ["changed": true, "deleted": id]
    }
    private static func save(_ devices: [[String: Any]]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["devices": devices], format: .xml, options: 0)
        try data.write(to: registryURL, options: .atomic)
        chmod(registryURL.path, 0o640)
    }
    public static func inspect(id: String, devices: [[String: Any]]) throws -> [String: Any] {
        guard var value = try list().first(where: { $0["id"] as? String == id }) else { throw ControlError("E_DEVICE_NOT_FOUND", "Unknown virtual device") }
        let uid = "coreaudio:device:org.audioroute.virtual.\(id)"
        value["published"] = devices.contains { $0["id"] as? String == uid }
        let path = root.appendingPathComponent("devices/\(id).shm").path
        if let transport = ar_transport_open(path, UInt32(value["inputChannels"] as? Int ?? 0), UInt32(value["outputChannels"] as? Int ?? 0), 0) {
            defer { ar_transport_close(transport) }
            var stats = ar_transport_stats(); ar_transport_get_stats(transport, &stats)
            value["active_clients"] = stats.active_clients
            value["driver_callbacks"] = stats.driver_callbacks
            value["underruns"] = stats.underruns; value["overruns"] = stats.overruns
        }
        return value
    }
}
