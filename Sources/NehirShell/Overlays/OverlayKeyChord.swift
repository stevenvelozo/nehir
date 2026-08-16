// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon.HIToolbox

/// A parsed in-overlay key chord (e.g. "space", "cmd+c", "shift+d") matched against
/// AppKit `NSEvent` key-downs while an overlay is focused. Distinct from
/// `DeckHotkeyChord`, which registers Carbon *global* hotkeys — this matches local
/// events so a developer can bind keys inside an overlay.
struct OverlayKeyChord {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static func parse(_ string: String) -> OverlayKeyChord? {
        var modifiers: NSEvent.ModifierFlags = []
        var keyCode: UInt16?
        for token in string.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " })
            .map(String.init)
        {
            switch token {
            case "cmd",
                 "command",
                 "⌘": modifiers.insert(.command)
            case "opt",
                 "option",
                 "alt",
                 "⌥": modifiers.insert(.option)
            case "ctrl",
                 "control",
                 "⌃": modifiers.insert(.control)
            case "shift",
                 "⇧": modifiers.insert(.shift)
            default: keyCode = keyCodes[token]
            }
        }
        guard let keyCode else { return nil }
        return OverlayKeyChord(keyCode: keyCode, modifiers: modifiers)
    }

    /// Matches when the key and the exact set of the four standard modifiers agree.
    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return event.modifierFlags.intersection(relevant) == modifiers
    }

    private static let keyCodes: [String: UInt16] = {
        var map: [String: UInt16] = [
            "space": UInt16(kVK_Space), "return": UInt16(kVK_Return), "enter": UInt16(kVK_Return),
            "tab": UInt16(kVK_Tab), "esc": UInt16(kVK_Escape), "escape": UInt16(kVK_Escape),
            "delete": UInt16(kVK_Delete), "left": UInt16(kVK_LeftArrow), "right": UInt16(kVK_RightArrow),
            "up": UInt16(kVK_UpArrow), "down": UInt16(kVK_DownArrow),
            "f1": UInt16(kVK_F1), "f2": UInt16(kVK_F2), "f3": UInt16(kVK_F3), "f4": UInt16(kVK_F4),
            "f5": UInt16(kVK_F5), "f6": UInt16(kVK_F6), "f7": UInt16(kVK_F7), "f8": UInt16(kVK_F8),
            "f9": UInt16(kVK_F9), "f10": UInt16(kVK_F10), "f11": UInt16(kVK_F11), "f12": UInt16(kVK_F12)
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
        for (name, code) in letters { map[name] = UInt16(code) }
        return map
    }()
}
