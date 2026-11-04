import AppKit

// A stand-in for an application that plays a video in fullscreen.
//
// The window fills the screen, the way a video in fullscreen does, and the
// app exposes an AXVideo container and a real Pause/Play button, as the
// playback search expects. Every change is written to a log file.
//
// Usage: video-app <log-file> <seconds>

final class Delegate: NSObject, NSApplicationDelegate {
    let logPath: String
    let duration: TimeInterval
    let label = NSTextField(labelWithString: "PLAYING")
    let playbackButton = NSButton(title: "Pause", target: nil, action: nil)
    var playing = true

    init(logPath: String, duration: TimeInterval) {
        self.logPath = logPath
        self.duration = duration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 932)
        // A window without a frame that fills the screen: a video in
        // fullscreen looks exactly like this.
        let window = NSWindow(contentRect: screen, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.title = "video"
        window.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1)
        let video = NSView(frame: NSRect(origin: .zero, size: screen.size))
        video.setAccessibilityElement(true)
        video.setAccessibilityRole(.group)
        video.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXVideo"))
        window.contentView = video
        label.font = NSFont.systemFont(ofSize: 96, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: screen.height / 2 - 60, width: screen.width, height: 120)
        video.addSubview(label)
        playbackButton.target = self
        playbackButton.action = #selector(togglePlayback(_:))
        playbackButton.frame = NSRect(x: screen.width / 2 - 60, y: 80, width: 120, height: 36)
        video.addSubview(playbackButton)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        write("playing")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSApp.terminate(nil)
        }
    }

    @objc private func togglePlayback(_ sender: NSButton) {
        playing.toggle()
        label.stringValue = playing ? "PLAYING" : "PAUSED"
        playbackButton.title = playing ? "Pause" : "Play"
        write(playing ? "playing" : "paused")
    }

    private func write(_ entry: String) {
        let text = (try? String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)) ?? ""
        try? (text + entry + "\n").write(to: URL(fileURLWithPath: logPath), atomically: true, encoding: .utf8)
    }
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/video-app.log"
let duration = CommandLine.arguments.count > 2 ? TimeInterval(CommandLine.arguments[2]) ?? 60 : 60
try? "".write(toFile: path, atomically: true, encoding: .utf8)
let app = NSApplication.shared
let delegate = Delegate(logPath: path, duration: duration)
app.delegate = delegate
app.run()
