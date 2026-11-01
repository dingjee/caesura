import AppKit

// A stand-in for an application that plays a video in fullscreen.
//
// The window fills the screen, the way a video in fullscreen does, and the
// app reacts to the media key of the keyboard the way a player does: it shows
// whether it plays or pauses. Every change is written to a log file, so a
// test can read it.
//
// Usage: video-app <log-file> <seconds>

/// The application that watches the events of the system: the media key of the
/// keyboard arrives as a system defined event.
final class VideoApplication: NSApplication {
    var onMediaKey: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .systemDefined, event.subtype.rawValue == 8 {
            let keyType = (event.data1 >> 16) & 0xFFFF
            let state = (event.data1 >> 8) & 0xFF
            // NX_KEYTYPE_PLAY, the key down.
            if keyType == 16, state == 0x0A {
                onMediaKey?()
            }
        }
        super.sendEvent(event)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    let logPath: String
    let duration: TimeInterval
    let label = NSTextField(labelWithString: "PLAYING")
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
        label.font = NSFont.systemFont(ofSize: 96, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: screen.height / 2 - 60, width: screen.width, height: 120)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        write("playing")
        (NSApplication.shared as? VideoApplication)?.onMediaKey = { [weak self] in
            guard let self else { return }
            self.playing = !self.playing
            self.label.stringValue = self.playing ? "PLAYING" : "PAUSED"
            self.write(self.playing ? "playing" : "paused")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSApp.terminate(nil)
        }
    }

    private func write(_ entry: String) {
        let text = (try? String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)) ?? ""
        try? (text + entry + "\n").write(to: URL(fileURLWithPath: logPath), atomically: true, encoding: .utf8)
    }
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/video-app.log"
let duration = CommandLine.arguments.count > 2 ? TimeInterval(CommandLine.arguments[2]) ?? 60 : 60
try? "".write(toFile: path, atomically: true, encoding: .utf8)
let app = VideoApplication.shared
let delegate = Delegate(logPath: path, duration: duration)
app.delegate = delegate
app.run()
