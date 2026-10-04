import Foundation

/// Agent-facing configuration reference. JSON Schema describes structure;
/// ScenarioSpec.validate and daemon preflight enforce cross-field/runtime rules.
enum ConfigurationHelp {
    static let schema: [String: Any] = {
        let identifier: [String: Any] = ["type": "string", "pattern": "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$"]
        let app: [String: Any] = ["type": "string", "pattern": "^app:.+$", "description": "Stable application identity app:<bundle-id>; PID-only identities are not accepted by the scenario validator."]
        let gain: [String: Any] = ["type": ["number", "null"], "minimum": -120, "maximum": 60, "default": 0, "description": "Finite dB; positive values boost above unity. Null or absence uses zero. Mute is a separate boolean."]
        let channelIndices: [String: Any] = ["type": "array", "minItems": 1, "maxItems": 64, "uniqueItems": true, "items": ["type": "integer", "minimum": 1, "maximum": 64], "description": "Unique one-based selected channels. Array order is the logical channel order."]
        func nullable(_ value: [String: Any]) -> [String: Any] { ["anyOf": [value, ["type": "null"]]] }
        func ref(_ name: String) -> [String: Any] { ["$ref": "#/$defs/\(name)"] }
        func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
            var result: [String: Any] = ["type": "object", "additionalProperties": false, "properties": properties]
            if !required.isEmpty { result["required"] = required }
            return result
        }
        func bool(_ defaultValue: Bool) -> [String: Any] { ["type": ["boolean", "null"], "default": defaultValue] }
        var metadata = object([
            "id": identifier,
            "name": ["type": ["string", "null"], "pattern": "\\S", "description": "Nonblank display name. Null or omission uses scenario.id."],
            "target_sample_rate": ["type": ["number", "null"], "minimum": 8000, "maximum": 192000, "default": 48000, "description": "Requested sample rate; each physical destination actually runs at its device's current rate, with resampling."],
            "latency_mode": ["enum": ["low", "balanced", "safe", NSNull()], "default": "low", "description": "Accepted metadata labels; the current engine does not guarantee distinct hardware buffer sizes for them."]
        ], required: ["id"])
        metadata["description"] = "Named scenario identity and requested settings."
        var input = object([
            "type": ["enum": ["device_input", "application_output", "virtual_output", "bus"]],
            "device": nullable(["type": "string", "minLength": 1, "description": "coreaudio:device:<UID> for physical sources; virtual:<registry-id>, coreaudio:device:org.audioroute.virtual.<registry-id>, registry ID or unambiguous registered name for virtual sources. Prefer stable IDs."]),
            "application": nullable(app),
            "source": nullable(identifier),
            "channels": ["anyOf": [channelIndices, ["type": "null"]], "default": [1, 2]],
            "trim_db": gain,
            "mute_original": bool(false),
            "mute": bool(false)
        ], required: ["type"])
        input["allOf"] = [
            ["if": ["properties": ["type": ["enum": ["device_input", "virtual_output"]]]],
             "then": ["required": ["device"], "properties": ["device": ["type": "string", "minLength": 1], "application": ["type": "null"], "source": ["type": "null"], "mute_original": ["enum": [false, NSNull()]]]]],
            ["if": ["properties": ["type": ["const": "application_output"]]],
             "then": ["required": ["application"], "properties": ["application": app, "device": ["type": "null"], "source": ["type": "null"]]]],
            ["if": ["properties": ["type": ["const": "bus"]]],
             "then": ["required": ["source"], "properties": ["source": identifier, "device": ["type": "null"], "application": ["type": "null"], "mute_original": ["enum": [false, NSNull()]]]]]
        ] as [[String: Any]]
        input["description"] = "device_input captures selected hardware channels; application_output uses an application process tap; virtual_output captures the application-written side of a virtual device. bus is supported by validation/offline rendering but rejected by the current live engine. Legacy engine strings device/application/virtual/pass_through are not valid scenario type aliases."
        let floatMaximum = Double(Float.greatestFiniteMagnitude)
        let channelMap: [String: Any] = [
            "anyOf": [
                ["enum": ["identity", "direct", "mono_to_stereo", "stereo", "stereo_to_mono"]],
                ["type": "array", "minItems": 1, "maxItems": 64,
                 "items": ["type": "array", "minItems": 1, "maxItems": 64,
                           "items": ["type": "number", "minimum": -floatMaximum, "maximum": floatMaximum]]],
                ["type": "null"]
            ],
            "description": "Named map or matrix with destination rows and source columns. Matrix dimensions must exactly match logical destination/source counts and weights must be finite Float32 values. identity/direct require equal counts; mono_to_stereo requires 1 -> 2; stereo requires 2 -> 2; stereo_to_mono requires 2 -> 1 and averages the source channels. Null/omission defaults to mono duplication for 1 -> 2 and otherwise identity."
        ]
        let mix = object(["gain_db": gain, "mute": bool(false), "map": channelMap])
        var output = object([
            "name": ["type": ["string", "null"], "description": "Optional display name; also names an auto-created virtual_input when no endpoint reference is supplied."],
            "type": ["enum": ["device_output", "virtual_input", "virtual_output", "bus"]],
            "device": ["type": ["string", "null"], "description": "Physical coreaudio:device:<UID>, or an explicit virtual endpoint reference where applicable."],
            "virtual_device": ["type": ["string", "null"], "description": "Explicit existing virtual endpoint registry ID or supported virtual identifier/name. Cannot be combined with a non-null device."],
            "consumer_application": nullable(app),
            "channels": ["anyOf": [["type": "integer", "minimum": 1, "maximum": 64], channelIndices, ["type": "null"]], "default": 2, "description": "Integer declares logical channels 1...N; an array selects physical channel indices. Live virtual destinations must select all published input channels in order."],
            "master_gain_db": gain,
            "mute": bool(false),
            "mix": ["type": "object", "minProperties": 1, "propertyNames": identifier, "additionalProperties": ref("mix"), "description": "Each key references one scenario input. Omitted inputs contribute nothing; input level, mute and mapping are independent for each output."]
        ], required: ["type", "mix"])
        output["allOf"] = [
            ["not": ["required": ["device", "virtual_device"], "properties": ["device": ["type": "string"], "virtual_device": ["type": "string"]]]],
            ["if": ["properties": ["type": ["const": "device_output"]]], "then": ["required": ["device"], "properties": ["device": ["type": "string", "minLength": 1]]]],
            ["if": ["properties": ["type": ["const": "virtual_input"]]], "then": ["properties": ["device": ["type": ["string", "null"], "minLength": 1], "virtual_device": ["type": ["string", "null"], "minLength": 1]]]]
        ] as [[String: Any]]
        output["description"] = "device_output plays physical PCM. virtual_input delivers a virtual microphone; with no device/virtual_device reference, apply creates it from name/output key. Explicit references require an existing endpoint. virtual_output is accepted by the validator, but the current live engine delivers it through a registered endpoint's input side; prefer virtual_input for microphone feeds. bus is validation/offline only."
        let policy = object([
            "reconnect": bool(true),
            "disconnected_input": ["enum": ["silence", NSNull()], "default": "silence"],
            "disconnected_output": ["enum": ["discard", NSNull()], "default": "discard"],
            "clip_protection": bool(true),
            "limiter_ceiling_dbfs": ["type": ["number", "null"], "minimum": -60, "maximum": 0, "default": -1, "description": "A hard sample clamp at this ceiling when clip_protection is enabled; not a transparent look-ahead limiter."],
            "allow_feedback": bool(false)
        ])
        var root = object([
            "version": ["type": "integer", "const": 1],
            "scenario": ref("metadata"),
            "inputs": ["type": "object", "minProperties": 1, "maxProperties": 64, "propertyNames": identifier, "additionalProperties": ref("input")],
            "outputs": ["type": "object", "minProperties": 1, "maxProperties": 64, "propertyNames": identifier, "additionalProperties": ref("output")],
            "policy": nullable(ref("policy"))
        ], required: ["version", "scenario", "inputs", "outputs"])
        root["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        root["$id"] = "urn:audioroute:scenario:1"
        root["title"] = "AudioRoute scenario version 1"
        root["description"] = "Structural JSON Schema for JSON or parsed restricted YAML. Unknown configuration fields fail. CLI scenario validate also applies cross-reference, map-dimension, feedback and machine-resource checks; this schema alone cannot prove a live audio path."
        root["$defs"] = ["metadata": metadata, "input": input, "output": output, "mix": mix, "policy": policy]
        root["x-audioroute-semantic-notes"] = [
            "Files must be UTF-8 and at most 1 MiB. Restricted YAML supports mappings, block/flow sequences, finite numbers, true/false/null, plain/quoted strings and comments; aliases, anchors, merge keys, tags, directives and multiline scalars are rejected.",
            "Every output.mix key must reference an input. A bus input.source must reference an output of type bus and select channels within that bus's logical channel count.",
            "Unless allow_feedback is true, active bus/virtual cycles and captured return -> virtual microphone loops for declared consumer_application are rejected. Physical duplex ports sharing a UID are separate ports. Undeclared application internals and acoustic feedback cannot be inferred.",
            "Only one live scenario may own each SPSC virtual transport direction. Duplicate virtual destination identities are rejected; aliases and name normalization also resolve at daemon preflight/apply.",
            "Virtual endpoints support at most 32 channels in each direction and currently publish at 48000 Hz; channel layout/clock are immutable per ID for the HAL host lifetime, with 128 distinct device slots. Schema's 64-channel bounds are configuration limits, not virtual-driver capacity.",
            "Final route gain is input trim + per-output input gain + output master gain, then channel-matrix weights. The engine rejects combined weights/gains that overflow Float32.",
            "Physical runtime I/O requires supported Float32 PCM and actual selected channels. Missing physical endpoints remain degraded and reconnect when policy.reconnect is true; missing explicitly referenced virtual endpoints fail preflight/apply.",
            "Capturing an AirPods microphone can change the headset's duplex profile and output format. Prefer a separate physical microphone when stereo listening is required. Application taps isolate processes belonging to a bundle, not individual browser tabs.",
            "Configuration success is separate from verification. Verify advancing callbacks, actual device-buffer delivery, expected source/mix signal, recent buffer health and virtual input reads. Reading-app identity and human audibility require separate confirmation."
        ]
        return root
    }()

    static let examples: [String: String] = [
        "physical-route": """
        version: 1
        scenario:
          id: physical-route
          name: Physical Route
          target_sample_rate: 48000
          latency_mode: low
        inputs:
          instrument:
            type: device_input
            device: coreaudio:device:INPUT_UID
            channels: [1]
            trim_db: 0
        outputs:
          headphones:
            type: device_output
            device: coreaudio:device:OUTPUT_UID
            channels: [1, 2]
            master_gain_db: 0
            mix:
              instrument:
                gain_db: -6
                map: mono_to_stereo
        policy:
          reconnect: true
          disconnected_input: silence
          disconnected_output: discard
          clip_protection: true
          limiter_ceiling_dbfs: -1
        """,
        "explicit-virtual-guitar-lesson": """
        version: 1
        scenario:
          id: guitar-lesson
          name: Guitar Lesson
          target_sample_rate: 48000
          latency_mode: low
        inputs:
          guitar:
            type: device_input
            device: coreaudio:device:GUITAR_INTERFACE_UID
            channels: [1]
            trim_db: 0
          voice:
            type: device_input
            device: coreaudio:device:SEPARATE_MICROPHONE_UID
            channels: [1]
            trim_db: 0
          teacher:
            type: virtual_output
            device: virtual:lesson-return
            channels: [1, 2]
            trim_db: 0
        outputs:
          teacher-send:
            name: Lesson Send
            type: virtual_input
            virtual_device: lesson-send
            consumer_application: app:us.zoom.xos
            channels: 2
            master_gain_db: 0
            mix:
              guitar:
                gain_db: -3
                map: mono_to_stereo
              voice:
                gain_db: 0
                map: mono_to_stereo
              teacher:
                mute: true
          listening:
            name: Listening Output
            type: device_output
            device: coreaudio:device:LISTENING_OUTPUT_UID
            channels: [1, 2]
            master_gain_db: 0
            mix:
              guitar:
                gain_db: -3
                map: mono_to_stereo
              voice:
                mute: true
              teacher:
                gain_db: -6
                map: stereo
        policy:
          reconnect: true
          disconnected_input: silence
          disconnected_output: discard
          clip_protection: true
          limiter_ceiling_dbfs: -1
          allow_feedback: false
        """
    ]

    static let exampleNotes: [String: [String]] = [
        "physical-route": [
            "Replace INPUT_UID and OUTPUT_UID with stable UIDs from audioroute devices list --json and choose actual available channels.",
            "This example requires microphone permission for the selected capture device; it does not require virtual devices or application process taps.",
            "Validate and dry-run before applying. Generate signal with the actual instrument, then inspect meter/status/verify; no test tone is emitted automatically."
        ],
        "explicit-virtual-guitar-lesson": [
            "Install/activate the AudioRoute HAL driver and system transport broker before creating virtual endpoints.",
            "Create the send microphone: audioroute virtual create \"Lesson Send\" --input 2 --output 0 --json. Its normalized registry ID is lesson-send.",
            "Create the application return destination: audioroute virtual create \"Lesson Return\" --input 0 --output 2 --json. Its normalized registry ID is lesson-return.",
            "Replace all physical placeholder UIDs with discovery results. Use a separate physical microphone to preserve AirPods stereo listening when applicable.",
            "In Zoom, select Lesson Send as microphone and Lesson Return as speaker/output. The return is captured from the virtual output, so this example uses no application process tap and does not require System Audio Recording permission.",
            "The teacher return is muted in the send and the voice is muted in listening. Guitar levels remain independent for the teacher and listening output.",
            "Confirm both third-party selections and actual audio delivery. Virtual input reads do not establish the reader's application identity; Bluetooth adds listening latency."
        ]
    ]
}
