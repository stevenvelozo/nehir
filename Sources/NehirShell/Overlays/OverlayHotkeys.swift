// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Carbon.HIToolbox
import Foundation

/// Registers any number of global chords, one per registered overlay, and
/// dispatches each press to that overlay's handler. Modeled on `DeckHotkey` but
/// keyed by id under a distinct four-char signature (`'NOVL'`), so it coexists
/// with the Deck's single-hotkey handler — each handler claims only its own
/// signature and returns `eventNotHandledErr` for anything else, so presses fall
/// through to whoever owns them.
@MainActor
final class OverlayHotkeys {
    private static let signature = OSType(0x4E4F_564C) // 'NOVL'

    private var handlerRef: EventHandlerRef?
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    /// Bind `chord` to `onTrigger`. Returns the assigned hotkey id (opaque; kept
    /// for a future unbind-by-id, unused for now).
    @discardableResult
    func register(chord: DeckHotkeyChord, onTrigger: @escaping () -> Void) -> UInt32 {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = onTrigger

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(chord.keyCode, chord.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotkeyRefs[id] = ref
        return id
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
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
            guard hotKeyID.signature == OverlayHotkeys.signature else {
                return OSStatus(eventNotHandledErr) // not ours — let another handler process it
            }
            let registry = Unmanaged<OverlayHotkeys>.fromOpaque(userData).takeUnretainedValue()
            var handled = false
            MainActor.assumeIsolated {
                if let action = registry.handlers[hotKeyID.id] {
                    action()
                    handled = true
                }
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    func unregisterAll() {
        for ref in hotkeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        handlers.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        nextID = 1
    }
}
