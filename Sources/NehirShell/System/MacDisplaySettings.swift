// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

/// Where the Dock lives on screen.
enum DockPosition: String, CaseIterable, Equatable {
    case bottom
    case left
    case right

    var title: String {
        rawValue.capitalized
    }
}

/// macOS "Show scroll bars" appearance setting (`AppleShowScrollBars` in the global
/// domain). Unset defaults to `.automatic` (macOS decides by input device).
enum ScrollBarMode: String, CaseIterable, Equatable {
    case automatic = "Automatic"
    case whenScrolling = "WhenScrolling"
    case always = "Always"

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .whenScrolling: "Scrolling"
        case .always: "Always"
        }
    }

    /// Next mode in the cycle: Auto → When scrolling → Always → Auto.
    var next: ScrollBarMode {
        let all = ScrollBarMode.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }
}

/// A snapshot of the screen-chrome settings the Deck's Display pane exposes.
struct DisplaySettings: Equatable {
    var menuBarAutoHide: Bool
    var dockAutoHide: Bool
    var dockMagnification: Bool
    var dockPosition: DockPosition
    var scrollBars: ScrollBarMode

    static let unknown = DisplaySettings(
        menuBarAutoHide: false,
        dockAutoHide: false,
        dockMagnification: false,
        dockPosition: .bottom,
        scrollBars: .automatic
    )
}

/// Reads and writes a few user macOS layout preferences via `CFPreferences`, restarting
/// the Dock to apply Dock changes. Nehir isn't sandboxed (it needs Accessibility), so it
/// can write the `com.apple.dock` and global domains for the current user and `killall`
/// the Dock — the same thing `defaults write … ; killall Dock` does.
///
/// Menu-bar auto-hide (`_HIHideMenuBar`) is a WindowServer-read global pref: it persists
/// immediately but may only take visual effect after the next login.
enum MacDisplaySettings {
    private static var dockDomain: CFString {
        "com.apple.dock" as CFString
    }

    private static let menuBarKey = "_HIHideMenuBar"

    static func current() -> DisplaySettings {
        DisplaySettings(
            menuBarAutoHide: bool(menuBarKey, app: kCFPreferencesAnyApplication),
            dockAutoHide: bool("autohide", app: dockDomain),
            dockMagnification: bool("magnification", app: dockDomain),
            dockPosition: DockPosition(rawValue: string("orientation", app: dockDomain) ?? "") ?? .bottom,
            scrollBars: ScrollBarMode(
                rawValue: string("AppleShowScrollBars", app: kCFPreferencesAnyApplication) ?? ""
            ) ?? .automatic
        )
    }

    static func setScrollBars(_ mode: ScrollBarMode) {
        set("AppleShowScrollBars", mode.rawValue as NSString, app: kCFPreferencesAnyApplication)
        // Nudge running apps to re-read the global appearance pref so most update without a
        // relaunch (the same notification System Settings posts when you change it there).
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("AppleShowScrollBarsSettingChanged"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    static func setMenuBarAutoHide(_ on: Bool) {
        // Drive it through System Events — the same path System Settings uses — so it
        // applies LIVE. A raw `_HIHideMenuBar` CFPreferences write persists but the menu
        // bar only re-renders after the next login, which reads as "the toggle does
        // nothing". (Needs the Automation permission Nehir requests on first use.)
        runSystemEvents("set autohide menu bar of dock preferences to \(on)")
    }

    static func setDockAutoHide(_ on: Bool) {
        set("autohide", NSNumber(value: on), app: dockDomain)
        restartDock()
    }

    static func setDockMagnification(_ on: Bool) {
        set("magnification", NSNumber(value: on), app: dockDomain)
        restartDock()
    }

    static func setDockPosition(_ position: DockPosition) {
        set("orientation", position.rawValue as NSString, app: dockDomain)
        restartDock()
    }

    // MARK: - CFPreferences helpers

    private static func bool(_ key: String, app: CFString) -> Bool {
        let value = CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }

    private static func string(_ key: String, app: CFString) -> String? {
        CFPreferencesCopyValue(key as CFString, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    private static func set(_ key: String, _ value: CFPropertyList, app: CFString) {
        CFPreferencesSetValue(key as CFString, value, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }

    /// Run a one-line System Events command (e.g. a `dock preferences` write) so the
    /// change applies live. Requires the Apple Events automation permission Nehir declares
    /// (`NSAppleEventsUsageDescription` + the automation entitlement); macOS prompts once.
    private static func runSystemEvents(_ command: String) {
        let source = "tell application \"System Events\" to \(command)"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
