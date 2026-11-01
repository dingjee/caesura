import Foundation
import CaesuraCore

// Native CLI entry: `caesura-cli <command> [options]`
// Local commands (help/version/logs) run here; everything else is forwarded as a JSON
// argv array over the UNIX socket of the running GUI instance (no shell involved).

var args = Array(CommandLine.arguments.dropFirst())

// Isolated data dir support for smoke tests: --data-dir must be the first argument.
var dataDirOverride: URL?
if args.first == "--data-dir", args.count >= 2 {
    dataDirOverride = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath, isDirectory: true)
    args = Array(args.dropFirst(2))
}

let command = Command(input: args, version: AppPaths.version)
let errorOutput = FileHandle.standardError

for message in command.errorMessages {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func runLocal() -> Never {
    switch command.command {
    case "version":
        print(command.versionText())
    case "logs":
        print(AppPaths.defaultLogURL.path)
    default:
        print(command.helpText())
    }
    exit(0)
}

if command.isLocalCommand {
    runLocal()
}

guard command.hasSupportedCommand else {
    exit(2)
}

let payload: [String: Any] = ["argv": args]
guard let data = try? JSONSerialization.data(withJSONObject: payload) else { exit(3) }

let result = CliForwarder.forward(argvJSON: data, socketURL: AppPaths.socketURL(dataDirectory: dataDirOverride))
switch result {
case .forwarded:
    break
case .noInstance:
    FileHandle.standardError.write("Caesura: no running native instance found at \(AppPaths.socketURL(dataDirectory: dataDirOverride).path)\n".data(using: .utf8)!)
    exit(4)
case .failed(let message):
    FileHandle.standardError.write(("Caesura: forwarding failed: \(message)\n").data(using: .utf8)!)
    exit(5)
}
