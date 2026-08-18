// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

@preconcurrency import AppKit
import Carbon
import Foundation

enum HotkeyRegistrationAction: Equatable {
    case command(HotkeyCommand)
}

struct HotkeyPlannedRegistration: Equatable {
    let binding: KeyBinding
    let action: HotkeyRegistrationAction

    init(binding: KeyBinding, command: HotkeyCommand) {
        self.binding = binding
        action = .command(command)
    }

    init(binding: KeyBinding, action: HotkeyRegistrationAction) {
        self.binding = binding
        self.action = action
    }
}

enum HotkeyRegistrationFailureReason: Equatable {
    case duplicateBinding
    case systemReserved
}

struct HotkeyRegistrationPlan: Equatable {
    let registrations: [HotkeyPlannedRegistration]
    var failures: [HotkeyCommand: HotkeyRegistrationFailureReason]
}

struct HotkeyRuntimeConfiguration: Equatable {
    let bindings: [HotkeyBinding]

    init(bindings: [HotkeyBinding] = []) {
        self.bindings = bindings
    }
}

@MainActor
final class HotkeyCenter {
    // >>> NEHIR-SHELL SEAM — Carbon signature for every hotkey this center registers
    // ('OMNI'). The event callback matches on signature *and* id so it never claims
    // another subsystem's hotkey (the Control Deck's 'NSHK', the overlays' 'NOVL') that
    // happens to share an id number — both sides number their ids from 1.
    private static let signature = OSType(0x4F4D_4E49) // 'OMNI'
    // <<< NEHIR-SHELL SEAM

    var onCommand: ((HotkeyCommand) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var isRunning = false
    private var idToAction: [UInt32: HotkeyRegistrationAction] = [:]
    private var configuration = HotkeyRuntimeConfiguration()

    private(set) var registrationFailures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

    deinit {
        MainActor.assumeIsolated {
            stop()
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
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
            // >>> NEHIR-SHELL SEAM — consume only hotkeys we registered, matched by BOTH our
            // signature and id, and pass everything else through (eventNotHandledErr) so a
            // handler installed before us — the Control Deck ('NSHK'), the overlay hotkeys
            // ('NOVL') — still receives them regardless of install order. The base handler
            // registers in startServices (gated on Accessibility); the Deck's registers in
            // activate. A mid-launch Accessibility grant installs the base handler last, so it
            // runs first: without the signature guard it matched the Deck's ⌘D by id alone (both
            // sides number from 1), swallowed it, and left ⌘D dead until the next launch.
            guard hotKeyID.signature == HotkeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let handled = MainActor.assumeIsolated {
                center.dispatch(id: hotKeyID.id)
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
            // <<< NEHIR-SHELL SEAM
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, selfPtr, &handler)

        registerHotkeys()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        unregisterAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    func updateBindings(_ newBindings: [HotkeyBinding], force: Bool = false) {
        let nextConfiguration = HotkeyRuntimeConfiguration(bindings: newBindings)
        guard force || nextConfiguration != configuration else { return }
        configuration = nextConfiguration
        if isRunning {
            registerHotkeys()
        }
    }

    private func unregisterAll() {
        for ref in refs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        refs.removeAll()
        idToAction.removeAll()
    }

    private func registerHotkeys() {
        unregisterAll()
        let plan = Self.registrationPlan(for: configuration.bindings)
        registrationFailures = plan.failures
        var nextId: UInt32 = 1

        for registration in plan.registrations {
            guard registrationFailuresForAction(registration.action).isEmpty else {
                continue
            }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: nextId)
            let status = RegisterEventHotKey(
                registration.binding.keyCode,
                registration.binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                idToAction[nextId] = registration.action
            } else {
                markSystemReservedFailure(for: registration.action)
            }
            nextId += 1
        }
    }

    private func registrationFailuresForAction(_ action: HotkeyRegistrationAction)
        -> [HotkeyRegistrationFailureReason]
    {
        switch action {
        case let .command(command):
            return registrationFailures[command].map { [$0] } ?? []
        }
    }

    private func markSystemReservedFailure(for action: HotkeyRegistrationAction) {
        switch action {
        case let .command(command):
            registrationFailures[command] = .systemReserved
        }
    }

    @discardableResult
    private func dispatch(id: UInt32) -> Bool {
        guard let action = idToAction[id] else { return false }
        switch action {
        case let .command(command):
            onCommand?(command)
        }
        return true
    }
}

extension HotkeyCenter {
    nonisolated static func registrationPlan(for bindings: [HotkeyBinding]) -> HotkeyRegistrationPlan {
        struct DirectCandidate {
            let command: HotkeyCommand
            let binding: KeyBinding
        }

        var directOwners: [KeyBinding: [HotkeyCommand]] = [:]
        var directCandidates: [DirectCandidate] = []
        var failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]

        func mark(_ command: HotkeyCommand, _ reason: HotkeyRegistrationFailureReason) {
            if failures[command] == nil {
                failures[command] = reason
            }
        }

        for binding in bindings {
            switch binding.binding {
            case .unassigned:
                continue
            case let .chord(keyBinding):
                guard !keyBinding.isUnassigned else { continue }
                directOwners[keyBinding, default: []].append(binding.command)
                directCandidates.append(DirectCandidate(command: binding.command, binding: keyBinding))
            }
        }

        for owners in directOwners.values where owners.count > 1 {
            for command in owners {
                mark(command, .duplicateBinding)
            }
        }

        var registrations: [HotkeyPlannedRegistration] = []
        for candidate in directCandidates {
            guard failures[candidate.command] == nil else { continue }
            registrations.append(HotkeyPlannedRegistration(binding: candidate.binding, command: candidate.command))
        }

        return HotkeyRegistrationPlan(
            registrations: registrations,
            failures: failures
        )
    }
}
