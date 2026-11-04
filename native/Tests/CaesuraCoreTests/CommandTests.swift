import Foundation
import CaesuraCore

enum CommandTests {
    static func registerAll() {
        TestRunner.register("command: bare invocation falls back to help", helpFallback)
        TestRunner.register("command: all 15 commands parse", allCommandsParse)
        TestRunner.register("command: unknown command rejected", unknownCommand)
        TestRunner.register("command: option aliases and values", options)
        TestRunner.register("command: invalid option reported", invalidOption)
        TestRunner.register("command: duration parsing (60, 1h, 1h20m, indefinitely, until-morning, junk)", durationParsing)
        TestRunner.register("command: wait parsing", waitParsing)
        TestRunner.register("command: local vs main-instance routing", routing)
        TestRunner.register("command: electron flags filtered before command", flagsFiltered)
        TestRunner.register("command: help text contains commands and examples", helpText)
    }

    static func helpFallback() throws {
        let command = Command(input: [], version: "1.22.1")
        try expectEqual(command.command, "help")
        try expectTrue(command.hasSupportedCommand)
    }

    static func allCommandsParse() throws {
        for name in Command.allCommands.keys {
            let command = Command(input: [name], version: "1.22.1")
            try expectTrue(command.hasSupportedCommand, "command \(name) should parse")
            try expectEqual(command.command ?? "", name)
        }
        // The legacy allCommands had 14 entries; the status of the running
        // instance is the fifteenth.
        try expectEqual(Command.allCommands.count, 15)
    }

    static func unknownCommand() throws {
        let command = Command(input: ["explode"], version: "1.22.1")
        try expectFalse(command.hasSupportedCommand)
        try expectFalse(command.errorMessages.isEmpty)
    }

    static func options() throws {
        let command = Command(input: ["long", "-T", "Stretch up!", "--text", "Go stretch!", "--noskip", "-w", "20m"], version: "1.22.1")
        try expectTrue(command.hasSupportedCommand)
        try expectEqual(command.options?["title"], "Stretch up!")
        try expectEqual(command.options?["text"], "Go stretch!")
        try expectEqual(command.options?["noskip"], "true")
        try expectEqual(command.options?["wait"], "20m")

        let mini = Command(input: ["mini", "-T", "Stretch up!", "--noskip"], version: "1.22.1")
        try expectEqual(mini.options?["title"], "Stretch up!")
        // -t is not valid for mini
        let miniText = Command(input: ["mini", "-t", "x"], version: "1.22.1")
        try expectFalse(miniText.errorMessages.isEmpty)
        try expectNil(miniText.options?["text"])
    }

    static func invalidOption() throws {
        let command = Command(input: ["pause", "--bogus"], version: "1.22.1")
        try expectTrue(command.hasSupportedCommand)
        try expectTrue(command.errorMessages.contains { $0.contains("--bogus") })
    }

    static func durationParsing() throws {
        // Legacy parseDuration: bare numbers are minutes ("pause -d 60" = one hour).
        try expectEqual(Command.parseDuration("60"), 3600000)
        try expectEqual(Command.parseDuration("1h"), 3600000)
        try expectEqual(Command.parseDuration("1H20M"), 4800000)
        try expectEqual(Command.parseDuration("20m"), 1200000)
        try expectEqual(Command.parseDuration("0"), -1)
        try expectEqual(Command.parseDuration("junk"), -1)
        try expectEqual(Command.parseDuration("1x"), -1)
        try expectEqual(Command.parseDuration("-5"), -1)

        let indefinite = Command(input: ["pause", "-d", "indefinitely"], version: "1")
        try expectEqual(indefinite.durationToMs(), 1)
        let minutes = Command(input: ["pause", "-d", "60"], version: "1")
        try expectEqual(minutes.durationToMs(), 3600000)
        let noDuration = Command(input: ["pause"], version: "1")
        try expectEqual(noDuration.durationToMs(), 1)
    }

    static func waitParsing() throws {
        let command = Command(input: ["mini", "-w", "90"], version: "1")
        try expectEqual(command.waitToMs(), 5400000)
        let none = Command(input: ["mini"], version: "1")
        try expectEqual(none.waitToMs(), 0)
    }

    static func routing() throws {
        for local in ["help", "version", "logs"] {
            let command = Command(input: [local], version: "1")
            try expectFalse(command.shouldExecuteInMain, "\(local) runs locally")
        }
        for remote in ["reset", "pause", "resume", "toggle", "postpone", "skip", "finish", "mini", "long", "last", "preferences"] {
            let command = Command(input: [remote], version: "1")
            try expectTrue(command.shouldExecuteInMain, "\(remote) forwards to main")
        }
    }

    static func flagsFiltered() throws {
        let command = Command(input: ["--remote-debugging-port=9222", "pause"], version: "1")
        try expectTrue(command.hasSupportedCommand)
        try expectEqual(command.command, "pause")
    }

    static func helpText() throws {
        let command = Command(input: [], version: "1.22.1")
        let text = command.helpText()
        for name in Command.allCommands.keys {
            try expectTrue(text.contains(name), "help mentions \(name)")
        }
        try expectTrue(text.contains("caesura pause -d 1h20m"))
        try expectTrue(command.versionText().contains("1.22.1"))
    }
}
