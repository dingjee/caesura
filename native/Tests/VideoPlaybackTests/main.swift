import AppKit
import Foundation

// The isolated compiler harness uses the production search/controller and its
// fake AX tree. Logging is quiet and cannot write to a persistent profile.
enum Log {
    static func info(_ message: String) {}
    static func warn(_ message: String) {}
}

if CommandLine.arguments.dropFirst() == ["--inspect-safari"] {
    guard VideoPlayback.canUseAccessibility else {
        print("accessibilityTrusted=false; no permission requested")
        exit(2)
    }
    guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else {
        print("Safari not running")
        exit(3)
    }
    let target = VideoPlayback.Target(bundleIdentifier: "com.apple.Safari",
        processIdentifier: safari.processIdentifier, name: "Safari")
    let observation = VideoPlayback.observe(target: target)
    // Only a state and identity checks, never titles or URLs; no AX action.
    print("state=\(observation.state)")
    print("recognizedYouTube=\(observation.container.flatMap { VideoPlayback.youtubeDocumentURL(of: $0) } != nil)")
    print("controlPIDMatches=\(observation.control?.processIdentifier == target.processIdentifier)")
    print("containerPIDMatches=\(observation.container?.processIdentifier == target.processIdentifier)")
    exit(observation.state == .playing || observation.state == .paused ? 0 : 1)
}

let results = MainActor.assumeIsolated { VideoPlaybackProbe.run() }
var count = 0, failures = 0
for (name, value) in results.sorted(by: { $0.key < $1.key }) {
    guard let passed = value as? Bool else { continue }
    count += 1
    if !passed { failures += 1; print("FAIL \(name)") }
}
print("video checks=\(count) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
