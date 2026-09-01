// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Carbon.HIToolbox
import Foundation

/// A parsed global chord, e.g. "cmd+d" -> (keyCode, Carbon modifier mask).
struct DeckHotkeyChord: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let commandD = DeckHotkeyChord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey))

    /// Parse strings like "cmd+d", "opt+cmd+space", "ctrl+shift+j". Falls back to
    /// ⌘D when a token can't be resolved — the right default for the *primary* summon.
    static func parse(_ string: String) -> DeckHotkeyChord {
        parseStrict(string) ?? .commandD
    }

    /// Like `parse`, but returns nil (instead of the ⌘D fallback) when the string doesn't
    /// resolve to a key plus at least one modifier. Callers that must NOT silently shadow ⌘D —
    /// the pass-through tap, whose head-insert placement would then consume ⌘D itself — use this
    /// to treat an unparseable chord as "disabled" rather than registering ⌘D.
    static func parseStrict(_ string: String) -> DeckHotkeyChord? {
        var modifiers: UInt32 = 0
        var keyCode: UInt32?
        for rawToken in string.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }) {
            let token = String(rawToken)
            switch token {
            case "cmd",
                 "command",
                 "⌘": modifiers |= UInt32(cmdKey)
            case "opt",
                 "option",
                 "alt",
                 "⌥": modifiers |= UInt32(optionKey)
            case "ctrl",
                 "control",
                 "⌃": modifiers |= UInt32(controlKey)
            case "shift",
                 "⇧": modifiers |= UInt32(shiftKey)
            default: keyCode = Self.keyCodes[token]
            }
        }
        guard let keyCode, modifiers != 0 else { return nil }
        return DeckHotkeyChord(keyCode: keyCode, modifiers: modifiers)
    }

    /// US-ANSI virtual key codes for the keys a trigger chord is likely to use.
    private static let keyCodes: [String: UInt32] = {
        var map: [String: UInt32] = [
            "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "tab": UInt32(kVK_Tab)
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
            ("8", kVK_ANSI_8), ("9", kVK_ANSI_9)
        ]
        for (name, code) in letters { map[name] = UInt32(code) }
        return map
    }()
}

/// Registers a single global hotkey (the Deck trigger) with Carbon.
///
/// Coexistence with the base window manager's own hotkey handler: both install a
/// handler on the shared application event target, and the base handler consumes
/// *every* hot-key event (it always returns `noErr`). Because NehirShell activates
/// after the base engine, this handler is installed later and therefore runs
/// first, so it sees the Deck chord before the base swallows it. It claims only
/// its own signature and returns `eventNotHandledErr` for anything else, so the
/// base's own hotkeys still reach the base handler untouched.
@MainActor
final class DeckHotkey {
    private static let signature = OSType(0x4E53_484B) // 'NSHK'
    private static let hotkeyID: UInt32 = 1

    private var handlerRef: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?
    private var onTrigger: (() -> Void)?

    func register(chord: DeckHotkeyChord, onTrigger: @escaping () -> Void) {
        unregister()
        self.onTrigger = onTrigger

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard hotKeyID.signature == DeckHotkey.signature, hotKeyID.id == DeckHotkey.hotkeyID else {
                return OSStatus(eventNotHandledErr) // not ours — let the base handler process it
            }
            let deck = Unmanaged<DeckHotkey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                deck.onTrigger?()
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotkeyID)
        RegisterEventHotKey(chord.keyCode, chord.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotkeyRef)
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        onTrigger = nil
    }
}
