import Foundation

/// Shared command parsing. The CLI and the GUI second-instance path
/// share this parser, so both accept exactly the same surface.
public struct Command {
    public struct OptionSpec {
        public let long: String
        public let short: String
        public let description: String
        public let withValue: Bool
    }

    public struct CommandSpec {
        public let description: String
        public let options: [OptionSpec]?
    }

    public static let allOptions: [String: OptionSpec] = [
        "title": OptionSpec(long: "--title", short: "-T", description: "Specify title for next break (Long or Mini)", withValue: true),
        "text": OptionSpec(long: "--text", short: "-t", description: "Specify text for next break (Long break only)", withValue: true),
        "noskip": OptionSpec(long: "--noskip", short: "-n", description: "Do not skip directly to this break (Long or Mini)", withValue: false),
        "wait": OptionSpec(long: "--wait", short: "-w", description: "Specify an interval to wait before skipping to this break (Long or Mini) [HHhMMm|HHh|MMm|MM]", withValue: true),
        "duration": OptionSpec(long: "--duration", short: "-d", description: "Specify duration for pausing breaks (Pause only) [indefinitely|until-morning|HHhMMm|HHh|MMm|MM]", withValue: true)
    ]

    public static let allCommands: [String: CommandSpec] = [
        "help": CommandSpec(description: "Show this help message", options: nil),
        "version": CommandSpec(description: "Show current Caesura version", options: nil),
        "logs": CommandSpec(description: "Show location of logs file", options: nil),
        "reset": CommandSpec(description: "Reset breaks", options: nil),
        "pause": CommandSpec(description: "Pause breaks", options: [allOptions["duration"]!]),
        "resume": CommandSpec(description: "Resume from a pause", options: nil),
        "toggle": CommandSpec(description: "Pause/unpause breaks", options: nil),
        "postpone": CommandSpec(description: "Postpone the currently running break, when allowed", options: nil),
        "skip": CommandSpec(description: "Skip the currently running break, when allowed", options: nil),
        "finish": CommandSpec(description: "Finish the currently running break, when allowed", options: nil),
        "mini": CommandSpec(description: "Skip to the Mini break, customize it", options: [allOptions["title"]!, allOptions["noskip"]!, allOptions["wait"]!]),
        "long": CommandSpec(description: "Skip to the Long break, customize it", options: [allOptions["text"]!, allOptions["title"]!, allOptions["noskip"]!, allOptions["wait"]!]),
        "last": CommandSpec(description: "Start the last Mini or Long break again", options: nil),
        "preferences": CommandSpec(description: "Open Preferences window", options: nil),
        "status": CommandSpec(description: "Show the status of the running application", options: nil)
    ]

    public static let examples: [(cmd: String, description: String)] = [
        ("caesura pause", "Pause breaks indefinitely"),
        ("caesura pause -d 60", "Pause breaks for one hour"),
        ("caesura pause -d 1h", "Pause breaks for one hour"),
        ("caesura pause -d 1h20m", "Pause breaks for one hour and twenty minutes"),
        ("caesura postpone", "Postpone the currently running break using existing preferences"),
        ("caesura skip", "Skip the currently running break using existing preferences"),
        ("caesura finish", "Finish the break after its countdown in Manual Finish mode"),
        ("caesura mini -T \"Stretch up!\"", "Start a Mini break, with the title \"Stretch up!\""),
        ("caesura long -T \"Stretch up!\" --noskip", "Set the next break's title to \"Stretch up!\""),
        ("caesura long -T \"Stretch up!\" -t \"Go stretch!\"", "Start a long break, with the title \"Stretch up!\" and text \"Go stretch!\""),
        ("caesura long -w 20m -T \"Stretch up!\"", "Wait 20 minutes, then start a long break with the title set to \"Stretch up!\""),
        ("caesura last", "Start the last break again, with the same idea"),
        ("caesura preferences", "Open Preferences window")
    ]

    public let version: String
    public private(set) var command: String?
    public private(set) var options: [String: String]?
    public private(set) var hasSupportedCommand = false
    public private(set) var errorMessages: [String] = []

    public init(input: [String], version: String) {
        self.version = version
        parse(input)
    }

    public var isLocalCommand: Bool {
        command == "version" || command == "help" || command == "logs"
    }

    /// Legacy `checkInMain`: whether the running main instance should act on it.
    public var shouldExecuteInMain: Bool {
        guard let command, !command.isEmpty else { return false }
        return !isLocalCommand
    }

    mutating func parse(_ input: [String]) {
        var args = input
        // Filter out Electron-style flags first (legacy behavior).
        while let first = args.first, first.hasPrefix("--") {
            args.removeFirst()
        }
        let rawCommand = args.first ?? "help"
        command = rawCommand
        guard let spec = Command.allCommands[rawCommand] else {
            errorMessages.append("Caesura: command '\(rawCommand)' is not supported")
            return
        }
        options = getOpts(Array(args.dropFirst()), spec: spec)
        hasSupportedCommand = true
    }

    mutating func getOpts(_ opts: [String], spec: CommandSpec) -> [String: String]? {
        guard let specOptions = spec.options else { return nil }
        var result: [String: String] = [:]
        var index = 0
        while index < opts.count {
            let name = opts[index]
            var valid = false
            for opt in specOptions {
                if opt.long == name || opt.short == name {
                    valid = true
                    if opt.withValue {
                        if index + 1 < opts.count {
                            result[String(opt.long.dropFirst(2))] = opts[index + 1]
                            index += 1
                        } else {
                            result[String(opt.long.dropFirst(2))] = ""
                        }
                    } else {
                        result[String(opt.long.dropFirst(2))] = "true"
                    }
                }
            }
            if !valid {
                errorMessages.append("Caesura: option '\(name)' is not valid for command '\(command ?? "")'")
            }
            index += 1
        }
        return result
    }

    // MARK: Duration parsing (legacy parseDuration; -1 means invalid)

    public func durationToMs(untilMorningMillis: Int64? = nil) -> Int64 {
        guard let duration = options?["duration"] else { return 1 }
        switch duration {
        case "indefinitely":
            return 1
        case "until-morning":
            return untilMorningMillis ?? 1
        default:
            return Self.parseDuration(duration)
        }
    }

    public func waitToMs() -> Int64 {
        guard let wait = options?["wait"] else { return 0 }
        return Self.parseDuration(wait)
    }

    /// Should return -1 when duration can't be parsed.
    public static func parseDuration(_ input: String) -> Int64 {
        let minToMs: Int64 = 60000
        if input.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            guard let mins = Int64(input) else { return -1 }
            let result = mins * minToMs
            return result > 0 ? result : -1
        }
        let lowered = input.lowercased()
        guard lowered.range(of: #"^(?:(\d+)h)?(?:(\d+)m)?$"#, options: .regularExpression) != nil else { return -1 }
        let hours = lowered.range(of: #"(\d+)h"#, options: .regularExpression).flatMap { Int64(lowered[$0].split(separator: "h")[0]) } ?? 0
        let minutes = lowered.range(of: #"(\d+)m"#, options: .regularExpression).flatMap { Int64(lowered[$0].split(separator: "m")[0]) } ?? 0
        let result = hours * minToMs * 60 + minutes * minToMs
        return result <= 0 ? -1 : result
    }

    // MARK: Help text (legacy formatting)

    public func helpText() -> String {
        var part = "Usage: caesura <command> [options]\n\nCommands:"
        let commandNames = Command.allCommands.keys.sorted()
        let longest = commandNames.map(\.count).max() ?? 0
        for name in commandNames {
            let spec = Command.allCommands[name]!
            let padding = String(repeating: " ", count: longest - name.count)
            part += "\n\tcaesura \(name)\(padding) \(spec.description)"
        }

        part += "\n\nOptions:"
        let optionKeys = Command.allOptions.keys.sorted { Command.allOptions[$0]!.long.count > Command.allOptions[$1]!.long.count }
        let longestOption = optionKeys.map { Command.allOptions[$0]!.long.count }.max() ?? 0
        for key in optionKeys {
            let opt = Command.allOptions[key]!
            let padding = String(repeating: " ", count: longestOption - opt.long.count)
            part += "\n\t\(opt.short), \(opt.long)\(padding) \(opt.description)"
        }

        part += "\n\nExamples:"
        let longestExample = Command.examples.map { $0.cmd.count }.max() ?? 0
        for example in Command.examples {
            let padding = String(repeating: " ", count: longestExample - example.cmd.count)
            part += "\n\t\(example.cmd)\(padding) \(example.description)"
        }
        return part
    }

    public func versionText() -> String {
        "Caesura version \(version)"
    }
}
