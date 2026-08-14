// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit

/// Key-event → `DeckKey` resolution for the Control Deck's event tap. Split out of
/// `ControlDeckController` so the controller body stays within the file-length budget.
extension ControlDeckController {
    /// Resolve a `DeckKey` from a captured key event (physical keys by keyCode; letters
    /// and digits by character). Enter accepts both Return (36) and keypad Enter (76).
    static func deckKey(from event: NSEvent) -> DeckKey? {
        switch event.keyCode {
        case 123: return .arrowLeft
        case 124: return .arrowRight
        case 125: return .arrowDown
        case 126: return .arrowUp
        case 53: return .escape
        case 49: return .space
        case 36,
             76: return .enter
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased().first,
                  character.isLetter || character.isNumber
            else { return nil }
            return .character(character)
        }
    }

    /// The digit 0…9 a key event types, if any (used for the ⌘+digit chord).
    static func digit(from event: NSEvent) -> Int? {
        guard let character = event.charactersIgnoringModifiers?.first,
              let value = character.wholeNumberValue, (0 ... 9).contains(value)
        else { return nil }
        return value
    }

    /// Whether a key event would type a visible character (so the Deck should swallow it
    /// rather than let a mistype reach the window below). Function/media/navigation keys
    /// return false and pass through.
    static func isTypographicKey(_ event: NSEvent) -> Bool {
        guard let character = event.charactersIgnoringModifiers?.first else { return false }
        return character.isLetter || character.isNumber || character.isPunctuation
            || character.isSymbol || character.isWhitespace
    }
}
