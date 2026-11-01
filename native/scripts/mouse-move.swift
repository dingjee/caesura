import AppKit
import CoreGraphics
import Foundation

// Moves the pointer of the user for a verification run.
//
// A warp alone moves the pointer without delivering any event, so the
// applications under it would not see the movement. The helper warps and
// posts the events, so both the system and the applications know where the
// pointer is.
//
// Usage: mouse-move <x> <y>
//        mouse-move --print     the pointer position (x y)
//        mouse-move --screen    the height of the screen in points
//
// The coordinates are in the coordinate system of the screen recording: the
// origin is in the top left corner.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first else {
    print("usage: mouse-move <x> <y> | --print | --screen")
    exit(2)
}

if first == "--print" {
    if let location = CGEvent(source: nil)?.location {
        print(Int(location.x), Int(location.y))
    } else {
        print("0 0")
    }
    exit(0)
}

if first == "--screen" {
    let height = NSScreen.screens.first?.frame.height ?? 0
    print(Int(height))
    exit(0)
}

guard arguments.count >= 2,
      let x = Double(arguments[0]),
      let y = Double(arguments[1]) else {
    print("usage: mouse-move <x> <y>")
    exit(2)
}

let source = CGEventSource(stateID: .combinedSessionState)
// The pointer moves in small steps: a single jump is not a movement.
for step in 0..<12 {
    let target = CGPoint(x: x + Double(step) * 0.4, y: y)
    CGWarpMouseCursorPosition(target)
    let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                        mouseCursorPosition: target, mouseButton: .left)
    event?.post(tap: .cghidEventTap)
    usleep(25_000)
}
print("moved to \(x),\(y)")
