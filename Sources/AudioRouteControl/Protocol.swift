import Foundation
import Darwin
import AudioRouteCore
import AudioRouteEngine

public struct ControlError: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { message }
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

public enum Paths {
    public static var state: URL {
        if let p = ProcessInfo.processInfo.environment["AUDIOROUTE_STATE_DIR"] { return URL(fileURLWithPath: p) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AudioRoute")
    }
    public static var socket: String {
        ProcessInfo.processInfo.environment["AUDIOROUTE_SOCKET"] ?? "/tmp/audioroute-\(getuid())/control.sock"
    }
    public static func prepare() throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = (socket as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(directory, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o077 == 0 else {
            throw ControlError("E_IPC_UNSAFE_PATH", "Socket directory must be a private directory owned by this user: \(directory)")
        }
    }
}

public enum Wire {
    public static let version = 1
    public static let maximumBytes = 4 * 1024 * 1024
    public static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw ControlError("E_IPC_PATH", "Socket path is too long") }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { ptr in ptr.copyBytes(from: bytes) }
        return value
    }
    public static func configure(_ fd: Int32) {
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    public static func send(_ object: [String: Any], to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        data.append(10)
        try data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), data.count - sent)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ControlError("E_IPC_WRITE", "Could not write to daemon socket") }
                sent += n
            }
        }
    }
    public static func receive(from fd: Int32) throws -> [String: Any] {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while data.count < maximumBytes {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ControlError("E_IPC_READ", "Connection closed or timed out before a complete response") }
            if let newline = buffer.prefix(n).firstIndex(of: 10) {
                guard data.count + newline <= maximumBytes else { throw ControlError("E_PROTOCOL_SIZE", "IPC message exceeds 4 MiB") }
                data.append(contentsOf: buffer[..<newline])
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ControlError("E_PROTOCOL", "Expected a JSON object") }
                return object
            }
            data.append(contentsOf: buffer.prefix(n))
        }
        throw ControlError("E_PROTOCOL_SIZE", "IPC message exceeds 4 MiB")
    }
    public static func request(_ command: String, arguments: [String: Any] = [:]) throws -> [String: Any] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("E_IPC_SOCKET", "Cannot create socket") }
        defer { Darwin.close(fd) }
        configure(fd)
        var address = try address(Paths.socket)
        let result = withUnsafePointer(to: &address) { ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw ControlError("E_DAEMON_NOT_RUNNING", "Cannot connect to audiorouted. Run 'audioroute daemon start'.") }
        try send(["protocol_version": version, "command": command, "arguments": arguments], to: fd)
        return try receive(from: fd)
    }
    public static func failure(_ error: Error) -> [String: Any] {
        let e = error as? ControlError
        return ["protocol_version": version, "ok": false, "error": ["code": e?.code ?? (error as? ConfigurationError)?.code ?? (error as? EngineError)?.code ?? "E_OPERATION_FAILED", "message": e?.message ?? (error as? ConfigurationError)?.message ?? (error as? EngineError)?.message ?? String(describing: error)]]
    }
}
