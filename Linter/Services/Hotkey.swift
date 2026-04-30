import AppKit
import Carbon.HIToolbox

struct Hotkey: Equatable, Codable, Hashable {
    /// Carbon virtual key code (e.g. `kVK_ANSI_L = 37`).
    var keyCode: UInt32
    /// Carbon modifier flags (e.g. `cmdKey | shiftKey`).
    var modifiers: UInt32

    static let `default` = Hotkey(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// Pretty rendering (`⌘⇧L`).
    var display: String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0  { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0   { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0     { parts += "⌘" }
        parts += Self.keyName(forKeyCode: keyCode)
        return parts
    }

    static func fromNSEvent(_ event: NSEvent) -> Hotkey? {
        let key = UInt32(event.keyCode)
        var mods: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command)   { mods |= UInt32(cmdKey) }
        if f.contains(.shift)     { mods |= UInt32(shiftKey) }
        if f.contains(.option)    { mods |= UInt32(optionKey) }
        if f.contains(.control)   { mods |= UInt32(controlKey) }
        guard mods != 0 else { return nil } // require at least one modifier
        return Hotkey(keyCode: key, modifiers: mods)
    }

    /// Returns a human-readable error if this chord conflicts with a system or
    /// in-app shortcut, or `nil` if it's safe to register globally.
    var validationError: String? {
        let hasCmd   = modifiers & UInt32(cmdKey)     != 0
        let hasShift = modifiers & UInt32(shiftKey)   != 0
        let hasOpt   = modifiers & UInt32(optionKey)  != 0
        let hasCtrl  = modifiers & UInt32(controlKey) != 0

        // Must have at least one modifier (already enforced in fromNSEvent,
        // but check again so loaded/seeded values are validated too).
        guard hasCmd || hasShift || hasOpt || hasCtrl else {
            return "Add a modifier (⌘, ⌃, ⌥, or ⇧)."
        }

        // Reject ⌘+single-key (covers ⌘C/V/X/Z/A/S/N/O/W/Q/F/P/T/H/M, ⌘+digit).
        // Standard rule: pure Cmd combos are reserved for app/system shortcuts.
        let onlyCmd = hasCmd && !hasShift && !hasOpt && !hasCtrl
        if onlyCmd {
            return "⌘\(Self.keyName(forKeyCode: keyCode)) conflicts with a system shortcut. Add ⇧, ⌥, or ⌃."
        }

        // Lone ⇧ / ⌥ / ⌃ alone with a key → too easy to trigger / collides
        // with text input. Require ⌘ as one of the modifiers.
        if !hasCmd {
            return "Include ⌘ in the chord."
        }

        // Explicit blocklist of well-known multi-modifier system chords.
        for entry in Self.systemChords where entry.matches(keyCode: keyCode, modifiers: modifiers) {
            return "\(display) conflicts with \(entry.label)."
        }

        // In-app conflicts.
        if (Int(keyCode) == kVK_Return || Int(keyCode) == kVK_ANSI_KeypadEnter) && isCmdOnly {
            return "⌘↩ is the in-app submit shortcut. Pick another chord."
        }

        return nil
    }

    private var isCmdOnly: Bool {
        let hasShift = modifiers & UInt32(shiftKey)   != 0
        let hasOpt   = modifiers & UInt32(optionKey)  != 0
        let hasCtrl  = modifiers & UInt32(controlKey) != 0
        let hasCmd   = modifiers & UInt32(cmdKey)     != 0
        return hasCmd && !hasShift && !hasOpt && !hasCtrl
    }

    private struct SystemChord {
        let key: Int
        let mods: UInt32
        let label: String
        func matches(keyCode: UInt32, modifiers: UInt32) -> Bool {
            Int(keyCode) == key && modifiers == mods
        }
    }

    private static let systemChords: [SystemChord] = {
        let cmdShift = UInt32(cmdKey | shiftKey)
        let cmdCtrl  = UInt32(cmdKey | controlKey)
        let cmdOpt   = UInt32(cmdKey | optionKey)
        return [
            .init(key: kVK_ANSI_3,    mods: cmdShift, label: "Screenshot (⌘⇧3)"),
            .init(key: kVK_ANSI_4,    mods: cmdShift, label: "Screenshot region (⌘⇧4)"),
            .init(key: kVK_ANSI_5,    mods: cmdShift, label: "Screenshot toolbar (⌘⇧5)"),
            .init(key: kVK_Space,     mods: cmdShift, label: "Input source (⌘⇧Space)"),
            .init(key: kVK_ANSI_Q,    mods: cmdCtrl,  label: "Lock screen (⌘⌃Q)"),
            .init(key: kVK_ANSI_F,    mods: cmdCtrl,  label: "Full screen (⌘⌃F)"),
            .init(key: kVK_Space,     mods: cmdCtrl,  label: "Emoji picker (⌘⌃Space)"),
            .init(key: kVK_Escape,    mods: cmdOpt,   label: "Force Quit (⌘⌥⎋)"),
        ]
    }()

    static func keyName(forKeyCode code: UInt32) -> String {
        // Special keys first.
        switch Int(code) {
        case kVK_Return:        return "↩"
        case kVK_Tab:            return "⇥"
        case kVK_Space:          return "Space"
        case kVK_Delete:         return "⌫"
        case kVK_Escape:         return "⎋"
        case kVK_LeftArrow:      return "←"
        case kVK_RightArrow:     return "→"
        case kVK_DownArrow:      return "↓"
        case kVK_UpArrow:        return "↑"
        case kVK_F1:  return "F1"; case kVK_F2:  return "F2"; case kVK_F3:  return "F3"
        case kVK_F4:  return "F4"; case kVK_F5:  return "F5"; case kVK_F6:  return "F6"
        case kVK_F7:  return "F7"; case kVK_F8:  return "F8"; case kVK_F9:  return "F9"
        case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        default: break
        }
        // Translate via current keyboard layout for printable keys.
        let layout = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let dataPtr = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else {
            return "?"
        }
        let layoutData = unsafeBitCast(dataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            UInt16(code),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &actualLength,
            &chars
        )
        if status == noErr, actualLength > 0 {
            return String(utf16CodeUnits: chars, count: actualLength).uppercased()
        }
        return "?"
    }
}

@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var callback: (() -> Void)?
    private var current: Hotkey?

    private static let signature: OSType = {
        // 'LNTR'
        let bytes: [UInt8] = [0x4C, 0x4E, 0x54, 0x52]
        return bytes.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()
    private static let id: UInt32 = 1

    func install(_ callback: @escaping () -> Void) {
        self.callback = callback
        if !handlerInstalled { installHandler() }
    }

    func setHotkey(_ hk: Hotkey) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            self.hotKeyRef = ref
            self.current = hk
        } else {
            NSLog("Linter: failed to register hotkey (status=\(status))")
        }
    }

    func currentHotkey() -> Hotkey? { current }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.callback?() }
                return noErr
            },
            1,
            &spec,
            context,
            nil
        )
        handlerInstalled = true
    }
}

/// Set to `true` while the user is recording a new global shortcut in the
/// settings panel. While true, `CommandKeyMonitor` lets keyDowns pass through
/// untouched so the recorder can capture chords like ⌘+Return that the monitor
/// would otherwise consume.
@MainActor
final class HotkeyRecordingState {
    static let shared = HotkeyRecordingState()
    var isRecording: Bool = false
    private init() {}
}

@MainActor
final class HotkeyStore {
    private static let key = "globalHotkey.v1"
    static let shared = HotkeyStore()

    private(set) var current: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(current) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data) {
            self.current = decoded
        } else {
            self.current = .default
        }
    }

    func set(_ hk: Hotkey) {
        current = hk
        GlobalHotkey.shared.setHotkey(hk)
    }
}
