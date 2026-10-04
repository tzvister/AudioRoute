import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import AVFoundation

struct Hardware {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(selector, scope: scope); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let err = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        return err == noErr ? result : []
    }
    static func ids(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] { ids(AudioObjectID(kAudioObjectSystemObject), selector) }
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, fallback: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T {
        var a = address(selector, scope: scope); var value = fallback; var size = UInt32(MemoryLayout<T>.size)
        _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return value
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector); var result: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &result) == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }
    static func channels(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: scope); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func sampleRates(_ object: AudioObjectID) -> [[Double]] {
        var a = address(kAudioDevicePropertyAvailableNominalSampleRates); var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        let err = ranges.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        return err == noErr ? ranges.map { [$0.mMinimum, $0.mMaximum] } : []
    }
    static func preferredStereoChannels(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var a = address(kAudioDevicePropertyPreferredChannelsForStereo, scope: scope)
        var pair = [UInt32](repeating: 0, count: 2)
        var size = UInt32(2 * MemoryLayout<UInt32>.size)
        let error = pair.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        guard error == noErr, size == 2 * MemoryLayout<UInt32>.size else { return [] }
        return pair.map(Int.init)
    }
    static func streams(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> [StreamInfo] {
        ids(object, kAudioDevicePropertyStreams, scope: scope).map { stream in
            StreamInfo(id: stream,
                startingChannel: value(stream, kAudioStreamPropertyStartingChannel, fallback: UInt32(0)),
                format: value(stream, kAudioStreamPropertyVirtualFormat, fallback: AudioStreamBasicDescription()))
        }
    }
    static func allDevices() -> [DeviceInfo] {
        ids(kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return DeviceInfo(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                input: channels(id, scope: kAudioObjectPropertyScopeInput), output: channels(id, scope: kAudioObjectPropertyScopeOutput),
                rate: value(id, kAudioDevicePropertyNominalSampleRate, fallback: 0.0),
                transport: value(id, kAudioDevicePropertyTransportType, fallback: UInt32(0)),
                alive: value(id, kAudioDevicePropertyDeviceIsAlive, fallback: UInt32(0)) != 0,
                inputStreams: streams(id, scope: kAudioObjectPropertyScopeInput),
                outputStreams: streams(id, scope: kAudioObjectPropertyScopeOutput))
        }
    }
    static func resolve(_ identifier: String?, devices: [DeviceInfo]) throws -> DeviceInfo? {
        guard let identifier else { return nil }
        let uid = identifier.replacingOccurrences(of: "coreaudio:device:", with: "")
        let exact = devices.filter { $0.uid == uid }
        if let first = exact.first { return first }
        let named = devices.filter { $0.name == identifier }
        if named.count > 1 { throw EngineError("E_DEVICE_AMBIGUOUS", "Several devices are named \(identifier); use a Core Audio UID.") }
        return named.first
    }
    static func checkFloatFormat(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws {
        let streams = ids(id, kAudioDevicePropertyStreams, scope: scope)
        for stream in streams {
            let format = value(stream, kAudioStreamPropertyVirtualFormat, fallback: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                format.mBytesPerFrame == 4 * (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : format.mChannelsPerFrame) else {
                throw EngineError("E_FORMAT_UNSUPPORTED", "Device \(id) does not expose Float32 PCM; its format was left unchanged.")
            }
        }
    }
    static func processes() -> [AudioProcess] {
        guard #available(macOS 14.2, *) else { return [] }
        return ids(kAudioHardwarePropertyProcessObjectList).map { id in
            AudioProcess(id: id, pid: value(id, kAudioProcessPropertyPID, fallback: Int32(0)),
                bundle: string(id, kAudioProcessPropertyBundleID) ?? "", playing: value(id, kAudioProcessPropertyIsRunningOutput, fallback: UInt32(0)) != 0)
        }
    }
}
struct StreamInfo {
    let id: AudioObjectID
    let startingChannel: UInt32
    let format: AudioStreamBasicDescription
    var json: [String: Any] {
        ["object_id": id, "starting_channel": startingChannel, "channels": format.mChannelsPerFrame,
         "sample_rate": format.mSampleRate, "format_id": format.mFormatID, "format_flags": format.mFormatFlags,
         "bits_per_channel": format.mBitsPerChannel, "bytes_per_frame": format.mBytesPerFrame]
    }
    var signature: String {
        "\(id):\(startingChannel):\(format.mChannelsPerFrame):\(format.mSampleRate):\(format.mFormatID):\(format.mFormatFlags):\(format.mBitsPerChannel):\(format.mBytesPerFrame)"
    }
}
struct DeviceInfo {
    var id: AudioDeviceID; var uid: String; var name: String; var input: Int; var output: Int; var rate: Double; var transport: UInt32; var alive: Bool
    var inputStreams: [StreamInfo]; var outputStreams: [StreamInfo]
    var streamLayoutSignature: String {
        // Stream order is significant: sorting would hide channel-layout changes.
        let input = inputStreams.map { $0.signature }.joined(separator: ",")
        let output = outputStreams.map { $0.signature }.joined(separator: ",")
        return input + "/" + output
    }
    var json: [String: Any] {
        let transports: [UInt32: String] = [kAudioDeviceTransportTypeBuiltIn: "built_in", kAudioDeviceTransportTypeUSB: "usb", kAudioDeviceTransportTypeBluetooth: "bluetooth", kAudioDeviceTransportTypeBluetoothLE: "bluetooth_le", kAudioDeviceTransportTypeVirtual: "virtual", kAudioDeviceTransportTypeAggregate: "aggregate", kAudioDeviceTransportTypeHDMI: "hdmi", kAudioDeviceTransportTypeDisplayPort: "displayport", kAudioDeviceTransportTypeThunderbolt: "thunderbolt"]
        let ranges = Hardware.sampleRates(id)
        return ["id": "coreaudio:device:\(uid)", "uid": uid, "name": name, "object_id": id, "transport": transports[transport] ?? "unknown", "input_channels": input, "output_channels": output, "current_sample_rate": rate, "sample_rate_ranges": ranges, "sample_rates": ranges.filter { $0[0] == $0[1] }.map { $0[0] }, "connected": alive,
            "buffer_frames": Hardware.value(id, kAudioDevicePropertyBufferFrameSize, fallback: UInt32(0)),
            "input_preferred_stereo_channels": Hardware.preferredStereoChannels(id, scope: kAudioObjectPropertyScopeInput),
            "output_preferred_stereo_channels": Hardware.preferredStereoChannels(id, scope: kAudioObjectPropertyScopeOutput),
            "input_streams": inputStreams.map { $0.json }, "output_streams": outputStreams.map { $0.json },
            "input_latency_frames": Hardware.value(id, kAudioDevicePropertyLatency, fallback: UInt32(0), scope: kAudioObjectPropertyScopeInput),
            "output_latency_frames": Hardware.value(id, kAudioDevicePropertyLatency, fallback: UInt32(0), scope: kAudioObjectPropertyScopeOutput)]
    }
}
struct AudioProcess { var id: AudioObjectID; var pid: Int32; var bundle: String; var playing: Bool }
public struct EngineError: Error, LocalizedError {
    public let code: String; public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}
