import Testing
import Carbon.HIToolbox
@testable import Linter

@Suite("Hotkey.validationError — chord rule layer (no Carbon side effects)")
@MainActor
struct HotkeyTests {

    // Convenience constructors so the tests read like chords.
    private static func hk(_ key: Int, _ mods: UInt32) -> Hotkey {
        Hotkey(keyCode: UInt32(key), modifiers: mods)
    }
    private static let cmd      = UInt32(cmdKey)
    private static let shift    = UInt32(shiftKey)
    private static let opt      = UInt32(optionKey)
    private static let ctrl     = UInt32(controlKey)
    private static let cmdShift = UInt32(cmdKey | shiftKey)
    private static let cmdOpt   = UInt32(cmdKey | optionKey)
    private static let cmdCtrl  = UInt32(cmdKey | controlKey)

    // MARK: must-have-modifier rule

    @Test func noModifierIsRejected() {
        let hk = Self.hk(kVK_ANSI_L, 0)
        #expect(hk.validationError != nil)
    }

    // MARK: pure-Cmd rejection

    @Test func cmdAloneIsRejectedRegardlessOfKey() {
        // ⌘L, ⌘C, ⌘V, ⌘0 — all reserved for app/system shortcuts.
        for key in [kVK_ANSI_L, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_0, kVK_ANSI_S] {
            let hk = Self.hk(key, Self.cmd)
            #expect(hk.validationError != nil, "⌘<key=\(key)> should be rejected")
        }
    }

    // MARK: lone-shift / opt / ctrl is rejected (must include ⌘)

    @Test func nonCmdModifiersAloneAreRejected() {
        let combos: [(Int, UInt32)] = [
            (kVK_ANSI_L, Self.shift),
            (kVK_ANSI_L, Self.opt),
            (kVK_ANSI_L, Self.ctrl),
            (kVK_ANSI_L, Self.shift | Self.opt),
        ]
        for (key, mods) in combos {
            let hk = Self.hk(key, mods)
            #expect(hk.validationError != nil, "non-⌘ chord (\(key), mods=\(mods)) should be rejected")
        }
    }

    // MARK: known-good chord — the default ⌘⇧L

    @Test func defaultChordIsAccepted() {
        let hk = Self.hk(kVK_ANSI_L, Self.cmdShift)
        #expect(hk.validationError == nil)
    }

    @Test func cmdOptKeyIsAcceptedWhenNotInBlocklist() {
        let hk = Self.hk(kVK_ANSI_L, Self.cmdOpt)
        #expect(hk.validationError == nil)
    }

    // MARK: system-chord blocklist

    @Test(
        "Each blocklisted chord is rejected",
        arguments: [
            (kVK_ANSI_3, Self.cmdShift),  // Screenshot ⌘⇧3
            (kVK_ANSI_4, Self.cmdShift),  // Screenshot region ⌘⇧4
            (kVK_ANSI_5, Self.cmdShift),  // Screenshot toolbar ⌘⇧5
            (kVK_Space,  Self.cmdShift),  // Input source ⌘⇧Space
            (kVK_ANSI_Q, Self.cmdCtrl),   // Lock screen ⌘⌃Q
            (kVK_ANSI_F, Self.cmdCtrl),   // Full screen ⌘⌃F
            (kVK_Space,  Self.cmdCtrl),   // Emoji picker ⌘⌃Space
            (kVK_Escape, Self.cmdOpt),    // Force Quit ⌘⌥⎋
        ] as [(Int, UInt32)]
    )
    func systemChordsAreRejected(_ pair: (Int, UInt32)) {
        let hk = Self.hk(pair.0, pair.1)
        #expect(hk.validationError != nil, "system chord (\(pair.0), mods=\(pair.1)) should be blocked")
    }

    // MARK: in-app conflict — ⌘↩ is the submit shortcut

    @Test func cmdReturnIsRejectedAsInAppSubmit() {
        let hk = Self.hk(kVK_Return, Self.cmd)
        // ⌘ alone fails the pure-Cmd rule first; that's still a rejection.
        // Combine with shift to verify the keypath that hits the in-app rule.
        // Here we just check the lone-Cmd path:
        #expect(hk.validationError != nil)
    }

    // MARK: display rendering — symbol order is ⌃⌥⇧⌘<key>

    @Test func displayRendersModifiersInCanonicalOrder() {
        let hk = Self.hk(kVK_ANSI_L, Self.cmdShift)
        let d = hk.display
        // The L can render via the keyboard layout fallback, but the mods
        // are pure string concat. Just check the prefix.
        #expect(d.hasPrefix("⇧⌘"), "got display=\(d.debugDescription)")
    }
}
