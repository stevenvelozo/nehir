// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// A *second* global summon chord for the OSD, built to reach across a Screen Sharing session.
///
/// The primary chord (`DeckHotkey`) is a Carbon `RegisterEventHotKey`, which the OS always
/// consumes on this machine — so it can never be forwarded to a remote workstation. This one
/// is a session `CGEventTap` instead, so it can *choose* per keystroke whether to consume the
/// chord or let it pass through:
///
///   • When a remote-desktop client (Screen Sharing, …) is the frontmost app, the keystroke is
///     let through untouched. Screen Sharing forwards it to the remote Mac, whose own Nehir
///     sees the chord with a *normal* app frontmost and opens the remote OSD.
///   • Otherwise the chord is consumed and the local OSD opens.
///
/// So a single identical config on every Mac gives you: ⌘D (Carbon) always-local, and this
/// chord "opens the OSD on whichever machine you're actually typing into." Requires the same
/// Accessibility trust the WM already holds.
@MainActor
final class DeckRemoteHotkey {
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var chord: DeckHotkeyChord?
    /// The exact device-independent modifier set the chord requires (derived from the chord's
    /// Carbon mask once at registration), compared against each event's flags.
    private var expectedFlags: NSEvent.ModifierFlags = []
    private var passthroughBundleIDs: Set<String> = []
    private var onTrigger: (() -> Void)?

    /// Whether a tap is currently installed (a non-empty chord was registered).
    var isRegistered: Bool { eventTap != nil }

    /// Install the always-on tap for `chord`. Tears down any prior tap first (idempotent), so
    /// re-registering with a new chord never orphans a tap that keeps eating keys.
    func register(chord: DeckHotkeyChord, passthroughBundleIDs: [String], onTrigger: @escaping () -> Void) {
        unregister()
        self.chord = chord
        expectedFlags = Self.modifierFlags(from: chord.modifiers)
        self.passthroughBundleIDs = Set(passthroughBundleIDs)
        self.onTrigger = onTrigger

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let remote = Unmanaged<DeckRemoteHotkey>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { remote.reenable() }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }
            // Hop only Sendable value types into the main-actor closure (the non-Sendable
            // CGEvent/NSEvent never cross the boundary), matching the Deck's own key tap.
            let keyCode = nsEvent.keyCode
            let modifierRawValue = nsEvent.modifierFlags.rawValue
            let isRepeat = nsEvent.isARepeat
            let consume = MainActor.assumeIsolated {
                remote.evaluate(keyCode: keyCode, modifierRawValue: modifierRawValue, isRepeat: isRepeat)
            }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
    }

    /// Remove the tap and clear all state.
    func unregister() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), eventTapSource, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
        chord = nil
        onTrigger = nil
    }

    /// Decide what to do with one keyDown: return `true` to consume it (our chord, handled
    /// locally), `false` to let it pass through (not our chord, or a remote-desktop client is
    /// focused so the chord should reach that session). `isRepeat` is the OS key-repeat flag.
    func evaluate(keyCode: UInt16, modifierRawValue: UInt, isRepeat: Bool) -> Bool {
        guard let chord else { return false }
        let relevant = NSEvent.ModifierFlags(rawValue: modifierRawValue)
            .intersection([.command, .option, .control, .shift])
        guard keyCode == UInt16(chord.keyCode), relevant == expectedFlags else { return false }
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           passthroughBundleIDs.contains(bundleID) {
            return false // pass through (repeats included) so it reaches the remote session
        }
        // Open the OSD once per physical press; swallow auto-repeats so a held chord doesn't
        // rapid-toggle (the Carbon primary fires exactly once — match that), but still consume
        // them so the chord never leaks to the app underneath.
        if !isRepeat { onTrigger?() }
        return true
    }

    private func reenable() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    /// Map a chord's Carbon modifier mask to the device-independent `NSEvent` flags used for
    /// per-event comparison.
    private static func modifierFlags(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }
}
