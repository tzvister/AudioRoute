import Foundation
import AudioRouteControl

/// Discovery is handled before command parsing or any daemon/socket access.
func handleDiscovery(_ arguments: [String]) throws -> Bool {
    let json = arguments.contains("--json")
    let tokens = arguments.filter { $0 != "--json" }
    func emit(_ result: Any) { output(["protocol_version": 1, "ok": true, "result": result]) }
    func usage(_ message: String) throws -> Never { throw ControlError("E_USAGE", message) }
    func render(_ records: [[String: Any]]) {
        for record in records {
            print("\n\(record["usage"] as? String ?? "")\n  \(record["summary"] as? String ?? "")")
            for section in ["arguments", "options"] {
                if let fields = record[section] as? [[String: Any]], !fields.isEmpty {
                    print("  \(section.capitalized):")
                    for field in fields { print("    \(field["name"] as? String ?? ""): \(field["description"] as? String ?? "")") }
                }
            }
            for section in ["notes", "examples"] {
                if let lines = record[section] as? [String], !lines.isEmpty {
                    print("  \(section.capitalized):")
                    for line in lines { print("    \(line)") }
                }
            }
        }
    }
    if tokens.isEmpty || tokens.first == "help" || tokens.contains("--help") {
        var topic: [String]
        if tokens.first == "help" {
            topic = Array(tokens.dropFirst()).filter { $0 != "--help" }
            guard topic.count <= 2 else { try usage("Expected help [COMMAND [SUBCOMMAND]].") }
        } else {
            let clean = tokens.filter { $0 != "--help" }
            // Positional values and flags on a command with --help never execute it.
            let first = clean.first ?? ""
            let hasSubcommands = CommandHelp.catalog.contains { ($0["name"] as? String ?? "").hasPrefix(first + " ") }
            topic = Array(clean.prefix(hasSubcommands ? 2 : 1))
        }
        let name = topic.joined(separator: " ")
        let records = CommandHelp.catalog.filter {
            let command = $0["name"] as? String ?? ""
            return name.isEmpty || command == name || command.hasPrefix(name + " ")
        }
        guard !records.isEmpty else { try usage("Unknown help topic '\(name)'. Run audioroute --help.") }
        if json {
            if name.isEmpty {
                emit(["name": "audioroute", "version": AudioRouteVersion.current, "commands": records,
                      "discovery": ["schema": "audioroute schema", "examples": "audioroute examples", "guide": "audioroute guide"],
                      "exit_codes": ["0": "success", "1": "operation failed", "2": "usage error", "3": "daemon unavailable", "4": "verification incomplete"],
                      "notes": ["Discovery commands work offline and never start the daemon.", "Operational responses are JSON, even without --json."]])
            } else { emit(["topic": name, "commands": records]) }
        } else if name.isEmpty {
            print("audioroute \(AudioRouteVersion.current) — scenario-first macOS audio routing\n")
            for record in records { print("  \(record["name"] as? String ?? "") — \(record["summary"] as? String ?? "")") }
            print("""

            Learn without external docs (no daemon required):
              audioroute guide                  Complete workflow and routing semantics
              audioroute help virtual create    Detailed command help
              audioroute level set --help       Same command help, flag form
              audioroute schema                 Scenario JSON Schema and semantic constraints
              audioroute examples               List ready-to-edit YAML examples
              audioroute --help --json           Machine-readable command catalog

            Operational output is JSON. Use --dry-run on mutations to preflight changes.
            Exit codes: 0 success, 1 operation failed, 2 usage, 3 daemon unavailable,
            4 verification incomplete. See guide for persistence and permissions.
            """)
        } else { render(records) }
        return true
    }
    switch tokens.first {
    case "--version":
        guard tokens.count == 1 else { try usage("Expected audioroute --version [--json].") }
        if json { emit(["name": "audioroute", "version": AudioRouteVersion.current]) }
        else { print("audioroute \(AudioRouteVersion.current)") }
    case "schema":
        guard tokens.count == 1 else { try usage("Expected audioroute schema [--json].") }
        emit(ConfigurationHelp.schema)
    case "guide":
        guard tokens.count == 1 else { try usage("Expected audioroute guide [--json].") }
        if json { emit(["guide": CommandHelp.guide]) } else { print(CommandHelp.guide) }
    case "examples":
        guard tokens.count <= 2 else { try usage("Expected audioroute examples [NAME] [--json].") }
        let names = ConfigurationHelp.examples.keys.sorted()
        if tokens.count == 1 {
            if json { emit(["examples": names, "notes": ConfigurationHelp.exampleNotes]) }
            else {
                print("Examples (audioroute examples NAME prints raw YAML):")
                for name in names {
                    print("\n  \(name)")
                    for note in ConfigurationHelp.exampleNotes[name] ?? [] { print("    \(note)") }
                }
                print("\nSave: audioroute examples NAME > scenario.yaml\nReplace placeholder device UIDs before applying. See audioroute guide.")
            }
        } else {
            let name = tokens[1]
            guard let yaml = ConfigurationHelp.examples[name] else { try usage("Unknown example '\(name)'. Available: \(names.joined(separator: ", ")).") }
            if json { emit(["name": name, "format": "yaml", "content": yaml, "notes": ConfigurationHelp.exampleNotes[name] ?? []]) }
            else { print(yaml) }
        }
    default: return false
    }
    return true
}
