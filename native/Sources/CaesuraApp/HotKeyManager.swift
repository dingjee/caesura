import Carbon.HIToolbox
import Foundation
import CaesuraCore

/// Global hotkeys registered through Carbon RegisterEventHotKey.
/// Accelerators like "CmdOrCtrl+X", "Command+Shift+Space", "Ctrl+Alt+F5" are parsed in
/// core-neutral code and mapped to virtual key codes.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private struct Registration {
        var hotKeyRef: EventHotKeyRef?
        var name: String
        var accelerator: String
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextIdentifier: UInt32 = 1
    private var handlerInstalled = false
    var onHotKey: ((String) -> Void)? // called with the settings key name

    // MARK: Accelerator parsing

    struct Accelerator: Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
    }

    static func parse(_ accelerator: String) -> Accelerator? {
        let parts = accelerator.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var modifiers: UInt32 = 0
        var keyToken: String?
        for part in parts {
            switch part.lowercased() {
            case "command", "cmd", "cmdorctrl", "commandorcontrol", "super":
                modifiers |= UInt32(cmdKey)
            case "ctrl", "control":
                modifiers |= UInt32(controlKey)
            case "alt", "option", "opt", "altgr":
                modifiers |= UInt32(optionKey)
            case "shift":
                modifiers |= UInt32(shiftKey)
            default:
                if keyToken == nil {
                    keyToken = part
                } else {
                    return nil // two key tokens: unsupported
                }
            }
        }
        guard let token = keyToken, let keyCode = keyCode(for: token) else { return nil }
        return Accelerator(keyCode: keyCode, modifiers: modifiers)
    }

    static func keyCode(for token: String) -> UInt32? {
        let single = token.count == 1 ? token.lowercased().first : nil
        if let character = single {
            let letters: [Character: UInt32] = [
                "a": UInt32(kVK_ANSI_A), "s": UInt32(kVK_ANSI_S), "d": UInt32(kVK_ANSI_D), "f": UInt32(kVK_ANSI_F),
                "h": UInt32(kVK_ANSI_H), "g": UInt32(kVK_ANSI_G), "z": UInt32(kVK_ANSI_Z), "x": UInt32(kVK_ANSI_X),
                "c": UInt32(kVK_ANSI_C), "v": UInt32(kVK_ANSI_V), "b": UInt32(kVK_ANSI_B), "q": UInt32(kVK_ANSI_Q),
                "w": UInt32(kVK_ANSI_W), "e": UInt32(kVK_ANSI_E), "r": UInt32(kVK_ANSI_R), "y": UInt32(kVK_ANSI_Y),
                "t": UInt32(kVK_ANSI_T), "o": UInt32(kVK_ANSI_O), "u": UInt32(kVK_ANSI_U), "i": UInt32(kVK_ANSI_I),
                "p": UInt32(kVK_ANSI_P), "l": UInt32(kVK_ANSI_L), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K),
                "n": UInt32(kVK_ANSI_N), "m": UInt32(kVK_ANSI_M)
            ]
            if let code = letters[character] { return code }
            let digits: [Character: UInt32] = [
                "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4),
                "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
                "9": UInt32(kVK_ANSI_9), "0": UInt32(kVK_ANSI_0)
            ]
            if let code = digits[character] { return code }
            switch character {
            case " ": return UInt32(kVK_Space)
            case "-": return UInt32(kVK_ANSI_Minus)
            case "=": return UInt32(kVK_ANSI_Equal)
            case "[": return UInt32(kVK_ANSI_LeftBracket)
            case "]": return UInt32(kVK_ANSI_RightBracket)
            case ";": return UInt32(kVK_ANSI_Semicolon)
            case "'": return UInt32(kVK_ANSI_Quote)
            case ",": return UInt32(kVK_ANSI_Comma)
            case ".": return UInt32(kVK_ANSI_Period)
            case "/": return UInt32(kVK_ANSI_Slash)
            case "\\": return UInt32(kVK_ANSI_Backslash)
            case "`": return UInt32(kVK_ANSI_Grave)
            default: return nil
            }
        }
        switch token.lowercased() {
        case "space": return UInt32(kVK_Space)
        case "tab": return UInt32(kVK_Tab)
        case "return", "enter": return UInt32(kVK_Return)
        case "escape", "esc": return UInt32(kVK_Escape)
        case "f1": return UInt32(kVK_F1)
        case "f2": return UInt32(kVK_F2)
        case "f3": return UInt32(kVK_F3)
        case "f4": return UInt32(kVK_F4)
        case "f5": return UInt32(kVK_F5)
        case "f6": return UInt32(kVK_F6)
        case "f7": return UInt32(kVK_F7)
        case "f8": return UInt32(kVK_F8)
        case "f9": return UInt32(kVK_F9)
        case "f10": return UInt32(kVK_F10)
        case "f11": return UInt32(kVK_F11)
        case "f12": return UInt32(kVK_F12)
        case "f13": return UInt32(kVK_F13)
        case "f14": return UInt32(kVK_F14)
        case "f15": return UInt32(kVK_F15)
        case "f16": return UInt32(kVK_F16)
        case "f17": return UInt32(kVK_F17)
        case "f18": return UInt32(kVK_F18)
        case "f19": return UInt32(kVK_F19)
        case "f20": return UInt32(kVK_F20)
        case "home": return UInt32(kVK_Home)
        case "end": return UInt32(kVK_End)
        case "pageup": return UInt32(kVK_PageUp)
        case "pagedown": return UInt32(kVK_PageDown)
        case "up": return UInt32(kVK_UpArrow)
        case "down": return UInt32(kVK_DownArrow)
        case "left": return UInt32(kVK_LeftArrow)
        case "right": return UInt32(kVK_RightArrow)
        default: return nil
        }
    }

    // MARK: Registration

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            DispatchQueue.main.async {
                HotKeyManager.shared.dispatch(identifier: hotKeyID.id)
            }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, nil)
        handlerInstalled = status == noErr
        if !handlerInstalled {
            Log.warn("Caesura: hotkey event handler installation failed (\(status))")
        }
    }

    private func dispatch(identifier: UInt32) {
        guard let registration = registrations[identifier] else { return }
        Log.info("Caesura: hotkey pressed (\(registration.name))")
        onHotKey?(registration.name)
    }

    /// Registers `accelerator` under `name` (a settings key). Re-registration replaces.
    @discardableResult
    func register(name: String, accelerator: String) -> Bool {
        guard !accelerator.isEmpty, let parsed = Self.parse(accelerator) else {
            Log.warn("Caesura: \(name) registration failed (cannot parse '\(accelerator)')")
            return false
        }
        installHandlerIfNeeded()
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53544C59) /* 'STLY' */, id: nextIdentifier)
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            Log.warn("Caesura: \(name) registration failed (\(status)) for '\(accelerator)' — key may be in use")
            return false
        }
        registrations[nextIdentifier] = Registration(hotKeyRef: hotKeyRef, name: name, accelerator: accelerator)
        nextIdentifier += 1
        Log.info("Caesura: \(name) registration successful (\(accelerator))")
        return true
    }

    func unregisterAll() {
        for (_, registration) in registrations {
            if let hotKeyRef = registration.hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
        registrations.removeAll()
    }

    /// Unregisters only the hotkeys registered under `name`; the other shortcuts
    /// (and their own dispatch) stay active.
    func unregister(name: String) {
        for (identifier, registration) in registrations where registration.name == name {
            if let hotKeyRef = registration.hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
            registrations.removeValue(forKey: identifier)
        }
    }

    /// True when a hotkey is currently registered under `name`.
    func isRegistered(name: String) -> Bool {
        registrations.values.contains { $0.name == name }
    }
}
