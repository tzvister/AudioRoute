import Foundation

/// Local help data: constructing or displaying it never contacts the daemon.
enum CommandHelp {
    private static func argument(_ name: String, _ description: String, required: Bool = true) -> [String: Any] {
        ["name": name, "description": description, "required": required]
    }
    private static func option(_ name: String, _ description: String) -> [String: Any] {
        ["name": name, "description": description]
    }
    private static let json = option("--json", "Return machine-readable JSON. Operational commands already emit a protocol_version/ok/result or error envelope.")
    private static let preview = option("--dry-run", "Describe the proposed change without applying it.")
    private static let yes = option("--yes", "Explicitly authorize deletion; required even with --dry-run.")
    private static func command(_ name: String, _ usage: String, _ summary: String,
                                arguments: [[String: Any]] = [], options: [[String: Any]] = [],
                                examples: [String] = [], notes: [String] = []) -> [String: Any] {
        ["name": name, "usage": usage, "summary": summary, "arguments": arguments,
         "options": options + [json], "examples": examples, "notes": notes]
    }

    static let catalog: [[String: Any]] = [
        command("help", "audioroute help [COMMAND [SUBCOMMAND]] [--json]", "Discover commands or inspect one command's usage without starting or contacting the daemon.",
                arguments: [argument("COMMAND [SUBCOMMAND]", "Command name, for example scenario apply.", required: false)],
                examples: ["audioroute help --json", "audioroute help scenario apply --json", "audioroute scenario apply --help"],
                notes: ["--help also works on command invocations. No arguments displays top-level help.", "JSON catalog records are in result.commands."]),
        command("schema", "audioroute schema [--json]", "Display the version 1 scenario JSON Schema locally.",
                examples: ["audioroute schema --json"],
                notes: ["JSON Schema is in result. Runtime capabilities and hardware availability still require scenario validate or apply --dry-run."]),
        command("examples", "audioroute examples [NAME] [--json]", "List bundled examples or print a complete YAML example locally.",
                arguments: [argument("NAME", "physical-route or explicit-virtual-guitar-lesson.", required: false)],
                examples: ["audioroute examples --json", "audioroute examples explicit-virtual-guitar-lesson > lesson.yaml"],
                notes: ["A named example prints YAML by default; --json returns its YAML in result.content. Replace hardware IDs using discovery before applying."]),
        command("guide", "audioroute guide [--json]", "Read the complete discovery, configuration, verification, and troubleshooting workflow locally.",
                examples: ["audioroute guide", "audioroute guide --json"]),
        command("setup", "audioroute setup [--start] [--json]", "Inspect first-run installation, broker, daemon, device publication, and permission health without applying a route.",
                options: [option("--start", "Explicitly start the daemon before inspection. Saved scenarios restore and can activate audio or permission prompts.")],
                examples: ["audioroute setup", "audioroute setup --json", "audioroute setup --start --json"],
                notes: ["Default setup is read-only; an absent daemon stays stopped. Inspection never runs an installer, requests permission, or restarts Core Audio.", "Reports exact next steps separately from checks. Signature validity does not establish notarization; installed files do not prove HAL loading.", "An empty virtual registry is normal. Unknown capture permissions require observation when the intended route is applied; setup cannot prove audio delivery."]),
        command("--version", "audioroute --version", "Print the CLI version locally.",
                examples: ["audioroute --version"], notes: ["Does not contact the daemon."]),
        command("daemon start", "audioroute daemon start [--dry-run] [--json]", "Start the bundled background app, or return the existing daemon's status.",
                options: [preview], examples: ["audioroute daemon start --json"],
                notes: ["Restores persisted scenarios and starts their routes; this can activate microphones and permission prompts.", "The bundled app is launched through LaunchServices so AudioRoute owns permissions. A sibling audiorouted executable is the development fallback.", "This does not install the HAL driver or register an automatic login service."]),
        command("daemon stop", "audioroute daemon stop [--dry-run] [--json]", "Stop the daemon and its active audio routes.",
                options: [preview], examples: ["audioroute daemon stop --json"],
                notes: ["Saved scenarios and virtual device identities remain; the next start restores scenarios."]),
        command("daemon status", "audioroute daemon status [--json]", "Read daemon PID, version, and startup restoration errors.",
                examples: ["audioroute daemon status --json"], notes: ["Does not start the daemon."]),
        command("devices list", "audioroute devices list [--json]", "Discover physical and published virtual Core Audio devices, stable IDs, directions, channels, and sample rates.",
                examples: ["audioroute devices list --json"], notes: ["Use returned coreaudio:device:<UID> IDs; display names and numeric object IDs are not stable selectors."]),
        command("devices inspect", "audioroute devices inspect ID [--json]", "Inspect one currently discovered Core Audio device.",
                arguments: [argument("ID", "Exact stable coreaudio:device:<UID> ID from devices list.")],
                examples: ["audioroute devices inspect coreaudio:device:org.audioroute.virtual.lesson-send --json"]),
        command("apps list", "audioroute apps list [--json]", "Discover running applications and their Core Audio processes and output activity.",
                examples: ["audioroute apps list --json"],
                notes: ["Use app:<bundle-id> for application_output capture. capture_available describes process discovery, not permission or successful capture.", "Application capture groups the app's audio processes; browser tabs are not separately addressable."]),
        command("apps playing", "audioroute apps playing [--json]", "List discovered applications whose Core Audio output processes are running.",
                examples: ["audioroute apps playing --json"], notes: ["audio_active/playing are process activity observations; they do not prove nonzero or audible audio."]),
        command("permissions", "audioroute permissions [--json]", "Inspect microphone permission, process-tap availability, and observed system-audio capture permission.",
                examples: ["audioroute permissions --json"], notes: ["Reading permissions does not request access. System-audio permission may be unknown until a real tap starts and produces callbacks."]),
        command("inspect", "audioroute inspect [--json]", "Get a combined inventory of devices, applications, permissions, and saved scenario IDs.",
                examples: ["audioroute inspect --json"]),
        command("virtual list", "audioroute virtual list [--json]", "List registered virtual device identities, publication state, and transport activity.",
                examples: ["audioroute virtual list --json"], notes: ["Registered and published are distinct: HAL publication is asynchronous and requires the installed driver/broker."]),
        command("virtual create", "audioroute virtual create NAME [--input N] [--output N] [--dry-run] [--json]", "Register a named virtual microphone, speaker, or duplex device.",
                arguments: [argument("NAME", "Display name, quoted when it contains spaces; its normalized slug becomes the device ID.")],
                options: [option("--input N", "App microphone channels, 0...32; default 2. Router writes, apps read."), option("--output N", "App speaker channels, 0...32; default 0. Apps write, router reads."), preview],
                examples: ["audioroute virtual create \"Lesson Send\" --input 2 --output 0 --json", "audioroute virtual create \"Lesson Return\" --input 0 --output 2 --json"],
                notes: ["At least one direction must have channels. Devices are fixed at 48000 Hz.", "An identical existing name/layout is a no-op; an ID collision or changed layout fails explicitly.", "Installation of the custom HAL driver and system transport broker requires an administrator. This command does not install either."]),
        command("virtual inspect", "audioroute virtual inspect ID [--json]", "Inspect a registry device's layout, publication, clients, callback counts, and buffer totals.",
                arguments: [argument("ID", "Registry slug from virtual list, for example lesson-send.")],
                examples: ["audioroute virtual inspect lesson-send --json"], notes: ["active_clients is a total count; it does not identify the app or prove microphone consumption."]),
        command("virtual delete", "audioroute virtual delete ID --yes [--dry-run] [--json]", "Remove a virtual device identity from the registry.",
                arguments: [argument("ID", "Registry slug from virtual list.")], options: [yes, preview],
                examples: ["audioroute virtual delete lesson-return --yes --dry-run --json"],
                notes: ["Remove scenario references and release app clients first. Deleting a device does not delete scenarios.", "Backing memory and HAL slots may remain while clients exist, for callback safety; deletion is not immediate reclamation."]),
        command("scenario list", "audioroute scenario list [--json]", "List saved scenario IDs.", examples: ["audioroute scenario list --json"]),
        command("scenario show", "audioroute scenario show ID [--json]", "Read the saved scenario specification, including persisted level changes.",
                arguments: [argument("ID", "Scenario ID, without the scenario: prefix.")], examples: ["audioroute scenario show guitar-lesson --json"]),
        command("scenario export", "audioroute scenario export ID [--json]", "Export the saved specification as JSON in the response envelope.",
                arguments: [argument("ID", "Scenario ID, without the scenario: prefix.")], examples: ["audioroute scenario export guitar-lesson --json"],
                notes: ["result is the scenario document. Extract result when saving a file for scenario apply; the entire response envelope is not a scenario."]),
        command("scenario validate", "audioroute scenario validate FILE [--json]", "Validate YAML/JSON configuration and perform side-effect-free runtime resource preflight.",
                arguments: [argument("FILE", "UTF-8 version 1 scenario YAML or JSON file, at most 1 MiB (effective parser limit).")], examples: ["audioroute scenario validate lesson.yaml --json"],
                notes: ["Requires the daemon for real resource inspection. Checks supported runtime types, channels/formats, endpoint ownership, and virtual resources.", "Does not start audio, create virtual devices, or request permissions. Missing physical resources may be reported as degraded resolution rather than invalid configuration.", "Successful validation cannot establish audible delivery or permission granted at stream start."]),
        command("scenario apply", "audioroute scenario apply FILE [--dry-run] [--json]", "Create or replace a scenario's entire runtime graph and persist its specification.",
                arguments: [argument("FILE", "UTF-8 version 1 scenario YAML or JSON file, at most 1 MiB (effective parser limit).")], options: [preview],
                examples: ["audioroute scenario apply lesson.yaml --dry-run --json", "audioroute scenario apply lesson.yaml --json"],
                notes: ["--dry-run performs the same preflight as validate without streaming, persistence, permission requests, or virtual creation.", "Reapplying the same ID replaces it; applying the same unchanged specification is idempotent.", "An unnamed-reference virtual_input output is created from its name or output key. Explicit virtual_device/device references and virtual_output sources must already exist.", "A successful apply means configuration accepted. Use verify with real signal and consumers, then confirm listening audibility.", "Permission prompts can occur when real streams/taps start. Graph replacement may briefly interrupt audio."]),
        command("scenario verify", "audioroute scenario verify ID [--json]", "Assess the live scenario from measured callbacks, signals, delivery, buffer health, and virtual consumption.",
                arguments: [argument("ID", "Saved scenario ID.")], examples: ["audioroute scenario verify guitar-lesson --json"],
                notes: ["Exit 0 means verification.working is true; exit 4 means verification is incomplete, including idle/silent required inputs.", "Send real signal through every effective required input and have the destination app actively reading the virtual microphone.", "Verification is a recent snapshot; it cannot prove the intended consumer's identity or human audibility."]),
        command("scenario delete", "audioroute scenario delete ID --yes [--dry-run] [--json]", "Stop and remove one persisted scenario.",
                arguments: [argument("ID", "Saved scenario ID.")], options: [yes, preview], examples: ["audioroute scenario delete guitar-lesson --yes --json"],
                notes: ["Virtual device identities are retained; delete them separately if no longer needed."]),
        command("status", "audioroute status [ID] [--json]", "Read current route state, endpoint connections, rates, gains, signals, counters, and actions.",
                arguments: [argument("ID", "Saved scenario ID; omit for all scenarios and daemon diagnostics.", required: false)], examples: ["audioroute status guitar-lesson --json"],
                notes: ["Status reconciles configured resources before measuring. A saved scenario can be running yet working=false while idle."]),
        command("meter", "audioroute meter [ID] [--json]", "Read a single meter/status snapshot; repeat the command for monitoring.",
                arguments: [argument("ID", "Saved scenario ID; omit for all scenarios.", required: false)], examples: ["audioroute meter guitar-lesson --json"],
                notes: ["There is no streaming/watch mode. Peak and RMS describe the latest audio block, not a query-interval peak hold.", "Signal threshold is -60 dBFS; lower-level audio/noise does not qualify. Source meters precede configured trim; sink meters describe mixed samples before clip protection.", "Counters accumulate for the current graph and reset on rebuild. Compare snapshots from the same graph; a single counter value cannot establish progression."]),
        command("doctor", "audioroute doctor [ID] [--json]", "Inspect measured verification, driver installation, stalled callbacks, clipping, buffer issues, permissions, and required app actions.",
                arguments: [argument("ID", "Saved scenario ID; omit for all scenarios.", required: false)], examples: ["audioroute doctor guitar-lesson --json"],
                notes: ["Reports diagnostic information; does not install drivers, change device selections, request permission, or generate test audio.", "Use scenario verify when an exit code for working/incomplete verification is needed."]),
        command("level set", "audioroute level set scenario:ID [output:NAME] [input:NAME] (--db DB | --master-db DB) [--dry-run] [--json]", "Adjust source trim, a single destination's input gain, or an output's master gain, then persist and rebuild the scenario.",
                arguments: [argument("scenario:ID", "Required saved scenario selector."), argument("input:NAME", "Input key: alone adjusts source trim; with output adjusts that output's mix only.", required: false), argument("output:NAME", "Output key: alone adjusts master; with input adjusts one mix route.", required: false)],
                options: [option("--db DB", "Finite gain in dB, -120...+60; for source trim or a selected output/input route."), option("--master-db DB", "Finite gain in dB, -120...+60; requires output without input."), preview],
                examples: ["audioroute level set scenario:guitar-lesson input:guitar --db 3 --json", "audioroute level set scenario:guitar-lesson output:teacher-send input:guitar --db -6 --json", "audioroute level set scenario:guitar-lesson output:listening --master-db -3 --dry-run --json"],
                notes: ["Positive dB is supported. Gains multiply: input trim + route gain + output master add in dB.", "Changing one output's mix leaves other destination mixes independent. Muted routes remain muted.", "--dry-run returns the proposed specification after semantic validation; it does not start/rebuild streams or perform the full hardware preflight.", "Changes update persisted daemon state, not the original YAML file. Reapplying the old file overwrites them."])
    ]

    static let guide = """
    AudioRoute agent workflow

    Discover the local interface before touching audio:
      audioroute help --json
      audioroute help scenario apply --json
      audioroute schema --json
      audioroute examples --json
      audioroute examples explicit-virtual-guitar-lesson > lesson.yaml
    help, guide, schema, examples, and --version require no daemon. Operational commands use a private local daemon; they do not start it implicitly.

    For first-run onboarding:
      audioroute setup
      audioroute setup --json
    Setup inspects OS/architecture, available app/CLI, installed HAL and broker files/signatures, broker registration, registry access, and any already-running daemon's inventory and permissions. It never installs software, restarts Core Audio, requests permission, or starts an absent daemon by default. An empty virtual registry is normal; files alone do not establish driver loading. Follow its coded next_steps only after reviewing the effects. To explicitly start the daemon and then inspect, use audioroute setup --start; starting restores saved routes and can activate audio or permission prompts. installation_ready is a filesystem/service assessment, not proof of permissions or audible routing. Setup keeps those observations separate and reports audio_verified: false.

    Start and inventory:
      audioroute daemon start --json
      audioroute inspect --json
      audioroute devices list --json
      audioroute apps playing --json
      audioroute permissions --json
    Copy stable device IDs and channel counts from discovery into the scenario. Physical IDs use coreaudio:device:<UID>; application capture uses app:<bundle-id>. Display names and numeric Core Audio object IDs are not stable hardware selectors. apps playing reports running output processes, not proof of audible samples.

    Virtual direction is from the target app's perspective:
      audioroute virtual create "Lesson Send" --input 2 --output 0 --json
      audioroute virtual create "Lesson Return" --input 0 --output 2 --json
    Lesson Send is an app microphone: the router writes to it and the app reads it. Use type: virtual_input as a scenario destination. Lesson Return is an app speaker: the app writes to it and the router reads it. Use type: virtual_output as a scenario input with device: lesson-return and channels: [1, 2]. Select Send as the target app's microphone and Return as its speaker. The CLI never selects app devices or changes macOS defaults. Keep the return source muted in the send mix to avoid feeding received call audio back to the caller.

    Virtual devices require the installed custom HAL plug-in and transport broker. Installation through scripts/install-driver.sh needs administrator access and the documented Core Audio reload/restart. virtual create only updates the registry. Use virtual inspect and devices list to check actual publication; registration is not publication. IDs are normalized name slugs. Channels (0...32 per direction) and 48000 Hz rate are immutable for an ID. Create explicit virtual source/destination references before applying. An output of type virtual_input without device/virtual_device is automatically created using its name or output key. Deleting a scenario does not delete devices; deleting a device does not remove scenario references.

    Configure, preflight, then apply:
      audioroute scenario validate lesson.yaml --json
      audioroute scenario apply lesson.yaml --dry-run --json
      audioroute scenario apply lesson.yaml --json
    A scenario is one complete version 1 YAML/JSON document, with named inputs, an independent mix for every output, and output master gains. Channels are one-based. The parser accepts its documented restricted YAML subset, not arbitrary YAML tags/anchors/features; JSON avoids YAML ambiguity. The effective document limit is 1 MiB in the model parser; the CLI also has an earlier 2 MiB guard. Unknown keys and invalid graph references, gains, maps, or feedback fail explicitly.

    validate and apply --dry-run need a running daemon to resolve real resources and formats. They are side-effect-free: no streams, permission requests, device creation, or persistence. A missing physical source/destination can resolve as degraded rather than invalid; unsupported runtime types, formats, channels, or ownership conflicts fail. Permission availability and actual delivery cannot be established by preflight. Real apply may request microphone or system-audio capture access for the daemon app. Use permissions and macOS Privacy & Security to inspect denied/unknown states; system-audio permission can remain unknown before a successful tap produces callbacks. Never infer permission from capture_available alone.

    Applying an existing scenario ID replaces its whole graph; repeating an unchanged specification is idempotent. A replacement is built and started before committing persisted state, then old callbacks stop before new callbacks activate. A brief gap is possible. Failure preserves the old runtime where replacement/persistence has not committed. Missing physical endpoints use silence/discard and can reconnect automatically when policy.reconnect is true. Virtual transport has one router producer per microphone device and one router reader per speaker device; ownership conflicts fail. Actual source and destination device rates govern their clocks; target_sample_rate is not a command to change hardware rates.

    Prove the route while signal and consumers are active:
      audioroute status guitar-lesson --json
      audioroute meter guitar-lesson --json
      audioroute scenario verify guitar-lesson --json
      audioroute doctor guitar-lesson --json
    Apply success means configuration accepted. working/verification requires connected endpoints, recent advancing callbacks, signal from every effective required source and output, healthy buffers, no clipping or invalid samples, and recent HAL microphone reads for virtual destinations. Silence/idle input can make working=false even though the graph is correctly running. Play/speak and generate target app return audio during verification. Signal is based on the latest block at a -60 dBFS threshold; absence does not prove the device is disconnected. A noisy input can cross the threshold; verify intended content separately.

    meter is a single snapshot, not a watch stream or peak hold. Peak/RMS reflect the latest processed block. Source meters precede trim; output meters measure the mix before sample clipping. Counters are cumulative for the current graph and reset on rebuild; compare two snapshots with the same graph to establish advancement or new xruns. callbacks_advancing uses recent callback timestamps rather than claiming continuous monitoring. Recently observed xruns keep verification unhealthy for at least one second. Physical output delivery counters show samples actually copied to valid device buffers; they cannot prove Bluetooth transmission, speaker volume, or human audibility. Listen to confirm the result.

    Virtual active_clients counts all clients and cannot identify the consuming app. input_consumption_observed uses actual recent HAL input reads; even a duplex client's intent can be ambiguous. consumer_application is a selection hint, not verified identity. doctor can recommend selecting the microphone even when another consumer is active. scenario verify exits 4 if its verification is incomplete; doctor/status/meter return observations without treating idle signal as a command failure.

    Change levels independently:
      audioroute level set scenario:guitar-lesson input:guitar --db 3 --json
      audioroute level set scenario:guitar-lesson output:teacher-send input:guitar --db -6 --json
      audioroute level set scenario:guitar-lesson output:listening --master-db -3 --json
    Source trim affects every destination. An output/input route gain affects only that output. Output master affects the complete destination mix. Positive gain is supported, each setting from -120 to +60 dB; combined gains multiply and can clip. Gains do not unmute routes. Level changes rebuild and persist the scenario, with a possible brief audio gap. Their --dry-run validates and returns a proposed document but does not run full hardware preflight.

    Persistence and cleanup:
      audioroute scenario show guitar-lesson --json
      audioroute scenario export guitar-lesson --json
      audioroute scenario delete guitar-lesson --yes --json
      audioroute virtual delete lesson-return --yes --json
      audioroute daemon stop --json
    Saved scenarios live in ~/Library/Application Support/AudioRoute/scenarios.json and restore on daemon start. Level commands modify that saved state, not the source YAML; reapplying an old file restores its old gains. Export returns the scenario in result: extract that object before using it as an apply file. Stop retains scenarios and virtual identities. Delete the scenario before removing devices it references and release target app clients. --yes is required for deletion, including dry-runs. Virtual shared mappings and HAL slots are retained for callback safety; up to 128 distinct identities can exist in a HAL host lifetime, reset by restarting that host/Mac. This is not an automatic-login service.

    Runtime boundaries:
    Physical I/O supports native Float32 Core Audio formats and selected channel indices; unsupported formats fail rather than silently convert device format. Application taps require macOS 14.2 or newer and select the app's Core Audio process list, not individual browser tabs. mute_original belongs only to application_output and mutes the explicitly tapped processes while tapped. Explicit virtual speaker routing removes the need for application capture and its permission, but requires the app to select that speaker. Internal bus configuration/offline rendering exists; the live engine explicitly rejects buses. A virtual_output destination accepted by the schema is not a speaker writer: live virtual destinations require published input channels; use virtual_input for clarity.

    Independent clocks use preallocated per-destination rings, buffered linear interpolation, and bounded drift correction. This adds buffering and is not a studio-quality resampler or a guaranteed latency bound. Bluetooth codecs/profiles add latency and microphone use can change playback behavior. Clip protection is a hard sample clamp at the configured ceiling, not a transparent look-ahead limiter. End-to-end latency, intended content, downstream application processing, remote-call delivery, and human audibility are not automatically proven. The CLI does not change default devices, app selections, hardware volume/rate, or generate a test tone automatically. This is a local development build with ad hoc signing unless configured otherwise, not a notarized installer.

    Responses and isolation:
    Operational stdout is JSON with protocol_version: 1 and ok. Success carries result; failure carries error.code/error.message. --json makes discovery/help formats explicitly machine-readable. Exit codes: 0 success, 1 operation failure, 2 usage, 3 daemon unavailable, 4 incomplete scenario verification. Newline-delimited JSON runs over a same-user private Unix socket; this is local control, not a remote network API. AUDIOROUTE_STATE_DIR and AUDIOROUTE_SOCKET can select a separate daemon state/socket for tests; use matching variables for CLI and daemon. Socket directories must be private and owned by the current user. The HAL registry and virtual devices remain system-wide even when daemon state/socket is isolated. Inspect daemon status restore_errors and the state directory's daemon.log when restoration or startup fails.
    """
}
