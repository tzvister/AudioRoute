import Foundation
import AppKit
import AudioRouteControl
import Darwin

// Core Audio and privacy services can deliver work to the application's main
// event loop. Keep socket/control operations off that loop, including device
// startup calls that may wait for macOS authorization.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
DispatchQueue.global(qos: .userInitiated).async {
    do { try Daemon.run(); exit(0) }
    catch {
        let data = (try? JSONSerialization.data(withJSONObject: Wire.failure(error), options: [.sortedKeys])) ?? Data()
        FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10])); exit(1)
    }
}
application.run()
