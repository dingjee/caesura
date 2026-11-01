import Foundation
import CaesuraCore

enum TrayIconTests {
    static func registerAll() {
        TestRunner.register("tray: default icon when style default", defaultIcon)
        TestRunner.register("tray: minutes number while running", minutesIcon)
        TestRunner.register("tray: progress while running", progressIcon)
        TestRunner.register("tray: no numeric suffix while paused or in break", noSuffix)
    }

    static func makeDescriptor(values: [String: SettingsValue], paused: Bool, reference: String? = "startMicrobreak", minutes: Int = 9, percentage: Int = 42) -> TrayIconDescriptor {
        TrayIconDescriptor(
            paused: paused,
            monochrome: values["useMonochromeTrayIcon"]?.boolValue ?? false,
            darkAppearance: false,
            trayIconStyle: values["trayIconStyle"]?.stringValue ?? "default",
            minutesRemaining: minutes,
            percentage: percentage,
            reference: reference
        )
    }

    static func defaultIcon() throws {
        let descriptor = makeDescriptor(values: ["trayIconStyle": .string("default")], paused: false)
        guard case .icon(let paused, let monochrome, let dark) = descriptor.appearance else {
            try fail("expected icon appearance")
        }
        try expectTrue(!paused && !monochrome && !dark)
    }

    static func minutesIcon() throws {
        let descriptor = makeDescriptor(values: ["trayIconStyle": .string("time")], paused: false, minutes: 9)
        guard case .minutes(let minutes, _, _, _) = descriptor.appearance else {
            try fail("expected minutes appearance")
        }
        try expectEqual(minutes, 9)
        // >= 100 minutes falls back to plain icon (legacy 0..99 bound)
        let tooMany = makeDescriptor(values: ["trayIconStyle": .string("time")], paused: false, minutes: 100)
        guard case .icon = tooMany.appearance else {
            try fail("expected fallback icon for 100 minutes")
        }
    }

    static func progressIcon() throws {
        let descriptor = makeDescriptor(values: ["trayIconStyle": .string("progress")], paused: false, percentage: 42)
        guard case .progress(let percent, _, _, _) = descriptor.appearance else {
            try fail("expected progress appearance")
        }
        try expectEqual(percent, 42)
    }

    static func noSuffix() throws {
        let paused = makeDescriptor(values: ["trayIconStyle": .string("time")], paused: true)
        guard case .icon = paused.appearance else {
            try fail("paused must not show minutes")
        }
        let running = makeDescriptor(values: ["trayIconStyle": .string("progress")], paused: false, reference: "finishBreak")
        guard case .icon = running.appearance else {
            try fail("finish reference must not show progress")
        }
        try expectFalse(running.showsNumericSuffix)
    }
}
