import AppKit
import Foundation
import CaesuraCore

// Native entry point. Launch modes:
// - GUI: `Caesura` (no arguments) or with CLI arguments that are forwarded to the
//   running instance when one exists (single-instance behavior like legacy).
// - Isolated runs (smoke tests): `--data-dir <path>` as the very first argument.

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--data-dir", arguments.count >= 2 {
    AppPaths.dataDirectoryOverride = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
    arguments = Array(arguments.dropFirst(2))
}

if arguments == ["--unregister-login-item"] || arguments == ["--login-item-status"] {
    guard TrialSupport.isTrial, !AppPaths.isIsolatedRun else { exit(2) }
    let status = LoginItemManager.currentStatus()
    print("Login item: \(status.rawValue)")
    if arguments == ["--login-item-status"] { exit(0) }
    if status == .notRegistered || status == .notFound { exit(0) }
    exit(LoginItemManager.setEnabled(false) ? 0 : 1)
}

let application = NSApplication.shared
let coordinator = AppCoordinator(launchArguments: arguments)
application.delegate = coordinator
application.setActivationPolicy(.accessory) // LSUIElement behavior
application.run()
