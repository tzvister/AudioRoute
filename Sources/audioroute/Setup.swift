import Foundation
import Darwin
import AudioRouteControl

private struct SetupProbe {
    let status: Int32?
    let diagnostic: String
}

/// Run only bounded, read-only diagnostic utilities, without invoking a shell.
private func setupProbe(_ executable: String, _ arguments: [String]) -> SetupProbe {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let timedOut = process.isRunning
        if timedOut { process.terminate() }
        // Never wait indefinitely for an inaccessible system diagnostic.
        let terminateDeadline = Date().addingTimeInterval(0.2)
        while process.isRunning && Date() < terminateDeadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return SetupProbe(status: timedOut ? nil : process.terminationStatus, diagnostic: timedOut ? "Diagnostic timed out; state is unknown." : output)
    } catch { return SetupProbe(status: nil, diagnostic: error.localizedDescription) }
}

private func setupQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func setupBundle(containing executable: URL) -> URL? {
    var candidate = executable.deletingLastPathComponent()
    while candidate.path != "/" {
        if candidate.pathExtension == "app" { return candidate }
        candidate.deleteLastPathComponent()
    }
    return nil
}

func setupReport(start: Bool) throws -> [String: Any] {
    let files = FileManager.default
    let cli = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    let daemonExecutable = try? daemonExecutableURL()
    let app = daemonExecutable.flatMap(setupBundle(containing:))
    let installedApp = URL(fileURLWithPath: "/Applications/AudioRoute.app")
    let driver = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/AudioRoute.driver")
    let broker = driver.appendingPathComponent("Contents/Resources/AudioRouteTransportBroker")
    let brokerPlist = "/Library/LaunchDaemons/org.audioroute.transport.plist"
    let sharedRoot = "/Library/Application Support/AudioRoute"
    var checks: [[String: Any]] = []
    var steps: [[String: Any]] = []
    func check(_ code: String, _ state: String, _ message: String, details: [String: Any] = [:]) {
        checks.append(["code": code, "state": state, "message": message, "details": details])
    }
    func step(_ code: String, _ description: String, command: String? = nil, admin: Bool = false) {
        var value: [String: Any] = ["code": code, "description": description, "requires_admin": admin]
        if let command { value["command"] = command }
        steps.append(value)
    }
    func signature(_ url: URL, code: String) -> Bool {
        let probe = setupProbe("/usr/bin/codesign", ["--verify", "--strict", url.path])
        check(code, probe.status == 0 ? "pass" : probe.status == nil ? "unknown" : "action_required",
              probe.status == 0 ? "Code signature verification passed; this does not establish notarization or distribution trust." : "Code signature verification did not pass.",
              details: ["path": url.path, "verified": probe.status == 0, "diagnostic": probe.diagnostic])
        return probe.status == 0
    }

    let supported = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0))
    var system = utsname()
    uname(&system)
    let machineCapacity = MemoryLayout.size(ofValue: system.machine)
    let architecture = withUnsafePointer(to: &system.machine) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: machineCapacity) { String(cString: $0) }
    }
    check("PLATFORM", supported ? "pass" : "action_required", "AudioRoute requires macOS 14.2 or newer.",
          details: ["os_version": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": architecture, "supported": supported])
    if !supported { step("UPDATE_MACOS", "Update macOS to 14.2 or newer before running audio routes.") }
    check("CLI", files.isExecutableFile(atPath: cli.path) ? "pass" : "unknown", "Inspecting the current CLI executable.", details: ["path": cli.path])
    check("DAEMON_EXECUTABLE", daemonExecutable == nil ? "action_required" : "pass", daemonExecutable == nil ? "No compatible daemon executable was found." : "A daemon executable is available.",
          details: ["path": daemonExecutable?.path ?? NSNull(), "bundled_app": app?.path ?? NSNull(), "applications_app_present": files.fileExists(atPath: installedApp.path)])
    var appVerified = false
    if let app { appVerified = signature(app, code: "APP_SIGNATURE") }
    else {
        check("APP_BUNDLE", "action_required", "The app bundle supplies a stable permission owner; a standalone development daemon is insufficient for complete onboarding.")
        step("INSTALL_APP", "Install the supplied AudioRoute package, or build the app bundle from the project. No download location is configured.")
    }

    let driverPresent = files.isExecutableFile(atPath: driver.appendingPathComponent("Contents/MacOS/AudioRoute").path)
    let brokerPresent = files.isExecutableFile(atPath: broker.path)
    let brokerPlistPresent = files.fileExists(atPath: brokerPlist)
    check("HAL_INSTALLED", driverPresent ? "pass" : "action_required", driverPresent ? "HAL plug-in files are installed; file presence alone does not prove that Core Audio loaded them." : "The custom HAL plug-in is missing.", details: ["path": driver.path])
    check("BROKER_INSTALLED", brokerPresent && brokerPlistPresent ? "pass" : "action_required", "Virtual audio requires the broker executable and its system launch service.", details: ["executable": broker.path, "executable_present": brokerPresent, "launch_plist": brokerPlist, "launch_plist_present": brokerPlistPresent])
    let driverVerified = driverPresent && signature(driver, code: "HAL_SIGNATURE")
    let brokerVerified = brokerPresent && signature(broker, code: "BROKER_SIGNATURE")
    let brokerProbe = setupProbe("/bin/launchctl", ["print", "system/org.audioroute.transport"])
    let brokerLoaded = brokerProbe.status == 0
    check("BROKER_LOADED", brokerLoaded ? "pass" : brokerProbe.status == nil ? "unknown" : "action_required",
          brokerLoaded ? "The broker service is registered in launchd's system domain; end-to-end audio is not tested." : "The broker service was not observed in the system launchd domain.",
          details: ["label": "org.audioroute.transport", "observed_loaded": brokerLoaded, "diagnostic": brokerLoaded ? "" : brokerProbe.diagnostic])
    let sharedWritable = files.isWritableFile(atPath: sharedRoot) && files.isWritableFile(atPath: sharedRoot + "/devices")
    check("VIRTUAL_REGISTRY_ACCESS", sharedWritable ? "pass" : "action_required", "The current user needs access to the shared virtual-device registry and transport directory.", details: ["path": sharedRoot, "writable": sharedWritable])

    // Discover development scripts only if they actually exist; never invent an installer URL.
    let candidateRoots = [cli.deletingLastPathComponent().deletingLastPathComponent(), URL(fileURLWithPath: files.currentDirectoryPath)]
    let project = candidateRoots.first { files.isExecutableFile(atPath: $0.appendingPathComponent("scripts/install-driver.sh").path) }
    if !driverPresent || !brokerPresent || !brokerPlistPresent || !sharedWritable || !driverVerified || !brokerVerified {
        if let project {
            let script = project.appendingPathComponent("scripts/install-driver.sh").path
            let builtDriver = project.appendingPathComponent("build/AudioRoute.driver").path
            if !files.fileExists(atPath: builtDriver) {
                step("BUILD", "Build the local development app, CLI, HAL plug-in, and broker first.", command: "cd " + setupQuote(project.path) + " && scripts/build.sh")
            }
            step("INSTALL_DRIVER", "Install the built HAL plug-in and broker with explicit administrator approval. This report never runs the installer.", command: "sudo " + setupQuote(script) + " " + setupQuote(builtDriver), admin: true)
        } else { step("INSTALL_DRIVER", "Install or repair the supplied AudioRoute package, which includes the HAL plug-in and broker. This report cannot install it.", admin: true) }
    }
    if driverPresent && brokerPresent && brokerPlistPresent && !brokerLoaded {
        step("LOAD_AUDIO_SERVICES", "After installation, restart the Mac to load the driver and broker. Reloading Core Audio interrupts current audio sessions; setup never does this automatically.")
        if let project, files.isExecutableFile(atPath: project.appendingPathComponent("scripts/activate-driver.sh").path) {
            step("EXPLICIT_AUDIO_RESTART", "Development alternative to restarting the Mac: explicitly activate the broker and restart Core Audio. This interrupts all current audio sessions.", command: "sudo " + setupQuote(project.appendingPathComponent("scripts/activate-driver.sh").path) + " --yes", admin: true)
        }
    }
    if !appVerified, let project {
        step("BUILD_APP", "Build/reinstall the app bundle before starting audio so microphone and system-audio permission have the intended owner.", command: "cd " + setupQuote(project.path) + " && scripts/build.sh")
    }

    var startup: Any = NSNull()
    if start { startup = try startDaemon() }
    var ping: [String: Any]?
    var inventory: [String: Any] = [:]
    var permissions: [String: Any] = [:]
    do {
        let response = try Wire.request("ping")
        if response["ok"] as? Bool == true { ping = response["result"] as? [String: Any] }
    } catch {
        check("DAEMON_CONNECTION", "info", "No daemon response is available; default setup does not start it.", details: ["diagnostic": String(describing: error)])
    }
    if ping != nil {
        check("DAEMON_RUNNING", "pass", "The daemon responded on this user's configured control socket.", details: ping!)
        for (command, assign) in [("inspect", 0), ("permissions", 1)] {
            do {
                let response = try Wire.request(command)
                if response["ok"] as? Bool == true, let result = response["result"] as? [String: Any] {
                    if assign == 0 { inventory = result } else { permissions = result }
                } else { check("DAEMON_" + command.uppercased(), "unknown", "The daemon could not provide this observation.", details: response) }
            } catch { check("DAEMON_" + command.uppercased(), "unknown", "The daemon observation failed.", details: ["diagnostic": String(describing: error)]) }
        }
        if let errors = ping?["restore_errors"] as? [[String: Any]], !errors.isEmpty {
            check("SCENARIO_RESTORE", "action_required", "Some saved routes failed to restore on startup.", details: ["errors": errors])
            step("DOCTOR", "Inspect the saved route restoration errors and current hardware.", command: "audioroute doctor --json")
        }
    } else {
        check("DAEMON_RUNNING", "info", "Daemon status, permissions, and loaded virtual devices cannot be inspected until the daemon runs.")
        step("START_DAEMON", "Start the daemon explicitly. Persisted scenarios restore and can activate microphones or permission prompts.", command: "audioroute setup --start")
    }

    var registered: [[String: Any]] = []
    var registryReadable = true
    do { registered = try VirtualRegistry.list() }
    catch {
        registryReadable = false
        check("VIRTUAL_REGISTRY_READ", "action_required", "The virtual registry could not be read; do not treat this as an empty installation.", details: ["diagnostic": String(describing: error)])
        step("INSPECT_REGISTRY", "Inspect the registry error before creating or deleting identities.", command: "audioroute virtual list --json")
    }
    let devices = inventory["devices"] as? [[String: Any]] ?? []
    let published = Set(devices.compactMap { $0["id"] as? String })
    let unpublished = registered.compactMap { entry -> String? in
        guard let id = entry["id"] as? String else { return nil }
        return published.contains("coreaudio:device:org.audioroute.virtual." + id) ? nil : id
    }
    if !registryReadable {
        check("HAL_PUBLICATION", "unknown", "Virtual device publication could not be compared with the unreadable registry.")
    } else if registered.isEmpty {
        check("HAL_PUBLICATION", "info", "No virtual devices are registered; an empty device list is normal and cannot prove the HAL is loaded.", details: ["registered_count": 0])
    } else if ping == nil {
        check("HAL_PUBLICATION", "unknown", "Registered devices exist but live publication was not inspected.", details: ["registered_count": registered.count])
    } else {
        check("HAL_PUBLICATION", unpublished.isEmpty ? "pass" : "action_required", unpublished.isEmpty ? "Registered virtual devices are visible to the daemon's Core Audio discovery." : "Some registered virtual devices are not visible to Core Audio; publication may still be pending.", details: ["registered_count": registered.count, "unpublished_ids": unpublished])
        if !unpublished.isEmpty { step("CHECK_PUBLICATION", "Recheck publication after installation/service activation; do not infer successful loading from files alone.", command: "audioroute virtual list --json") }
    }
    let microphone = permissions["microphone"] as? String ?? "unknown"
    let systemAudio = permissions["system_audio"] as? String ?? "unknown"
    check("MICROPHONE_PERMISSION", microphone == "granted" ? "pass" : ["denied", "restricted"].contains(microphone) ? "action_required" : "unknown",
          "Microphone permission: " + microphone + ". Setup does not request permission.", details: permissions)
    if ["denied", "restricted"].contains(microphone) {
        step("GRANT_MICROPHONE", "Grant AudioRoute microphone access in System Settings > Privacy & Security > Microphone, then retry the intended route.")
    } else if microphone != "granted" {
        step("FIRST_CAPTURE", "After reviewing and applying a scenario with a physical input, macOS may request microphone access. Setup cannot grant or preflight it.", command: "audioroute guide")
    }
    check("SYSTEM_AUDIO_PERMISSION", systemAudio == "capture_observed" ? "pass" : systemAudio == "tap_failed" ? "action_required" : "unknown",
          "Application-tap permission: " + systemAudio + ". There is no side-effect-free system-audio permission preflight.")
    if systemAudio != "capture_observed" {
        step("APP_CAPTURE_PERMISSION", "Only application_output routes require process-tap capture permission. A real tap must start to request/observe it; explicit virtual speaker routing avoids that permission. A tap failure can have causes besides denial.", command: "audioroute guide")
    }
    step("CONFIGURE", "Use discovered device IDs to edit a bundled example, validate and dry-run it, then apply only the reviewed route. Select virtual devices in the target app and verify with actual signal.", command: "audioroute examples explicit-virtual-guitar-lesson")
    step("WORKFLOW", "Read the discovery, virtual direction, persistence, and measured verification workflow.", command: "audioroute guide")
    let installationReady = supported && appVerified && driverVerified && brokerVerified && brokerPlistPresent && brokerLoaded && sharedWritable && registryReadable
    let paths: [String: Any] = ["cli": cli.path, "daemon": daemonExecutable?.path as Any? ?? NSNull(), "app": app?.path as Any? ?? NSNull(), "driver": driver.path, "broker": broker.path, "state": Paths.state.path, "socket": Paths.socket]
    return ["mode": start ? "start_and_inspect" : "read_only", "started_requested": start, "startup": startup,
            "status": checks.contains { $0["state"] as? String == "action_required" } ? "action_required" : "observations_available",
            "installation_ready": installationReady, "daemon_running": ping != nil, "audio_verified": false,
            "permissions": permissions, "checks": checks, "next_steps": steps,
            "paths": paths,
            "note": "Installation checks, permission observations, and a responding daemon do not prove an audio route. Unknown permissions require observation during intended capture; scenario verification and human listening remain separate."]
}

func printSetupReport(_ report: [String: Any]) {
    print("AudioRoute setup")
    print(report["installation_ready"] as? Bool == true ? "Installed components are ready." : "Installed components need attention.")
    print(report["daemon_running"] as? Bool == true ? "The background app is running." : "The background app is stopped or could not be reached.")
    let permissions = report["permissions"] as? [String: Any] ?? [:]
    switch permissions["microphone"] as? String {
    case "granted": print("Microphone access is granted.")
    case "denied", "restricted": print("Microphone access needs attention in System Settings.")
    default: print("Microphone access is not yet confirmed. macOS can ask when you apply a route that captures a physical input.")
    }
    print("Setup does not test sound or change your audio settings.")
    print("\nNext steps:")
    for step in report["next_steps"] as? [[String: Any]] ?? [] {
        // Unknown process-tap permission is normal and irrelevant to virtual-speaker onboarding.
        if ["APP_CAPTURE_PERMISSION", "FIRST_CAPTURE"].contains(step["code"] as? String ?? "") { continue }
        print("- " + (step["description"] as? String ?? ""))
        if let command = step["command"] as? String { print("  " + command) }
    }
    print("\nUse audioroute setup --json for the full diagnostic report.")
}
