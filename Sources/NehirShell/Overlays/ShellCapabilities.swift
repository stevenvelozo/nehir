// SPDX-FileCopyrightText: 2026 Steven Velozo
// SPDX-FileComment: Provenance=nehir-original; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import FableCore
import Foundation
import UserNotifications

/// Native `shell.*` actions exposed to the JavaScript host, so user scripts (and
/// overlay key handlers) can do real work: clipboard, file actions, notifications,
/// Quick Look, and running a shell command. These are the user's own scripts
/// controlling their own machine — the same trust model as any dotfile.
@MainActor
enum ShellCapabilities {
    static func install(on core: FableCore, quickLook: OverlayQuickLook) {
        core.installHostFunctions(namespace: "shell", [
            // Put a string on the clipboard.
            "clipboard": { args in
                guard let text = args.string(at: 0) else { return false }
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(text, forType: .string)
            },
            // Reveal a file in Finder.
            "reveal": { args in
                if let path = args.string(at: 0) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL(path)])
                }
                return nil
            },
            // Open a file/URL with its default handler.
            "open": { args in
                guard let target = args.string(at: 0) else { return false }
                if let url = URL(string: target), url.scheme != nil, !target.hasPrefix("/") {
                    return NSWorkspace.shared.open(url)
                }
                return NSWorkspace.shared.open(fileURL(target))
            },
            // Move a file to the Trash (recoverable). Returns whether it succeeded.
            "trash": { args in
                guard let path = args.string(at: 0) else { return false }
                do {
                    try FileManager.default.trashItem(at: fileURL(path), resultingItemURL: nil)
                    return true
                } catch {
                    core.log(.error, "shell.trash failed", ["path": path, "error": String(describing: error)])
                    return false
                }
            },
            // Quick Look a file in place.
            "quickLook": { args in
                if let path = args.string(at: 0) { quickLook.preview(fileURL(path)) }
                return nil
            },
            // Run a shell command (/bin/sh -c), fire-and-forget.
            "run": { args in
                guard let command = args.string(at: 0) else { return false }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                do {
                    try process.run()
                    return true
                } catch {
                    core.log(.error, "shell.run failed", ["command": command, "error": String(describing: error)])
                    return false
                }
            },
            // Post a user notification (best-effort; requires notification permission).
            "notify": { args in
                notify(title: args.string(at: 0) ?? "", body: args.string(at: 1) ?? "")
                return nil
            }
        ])
    }

    // MARK: - Helpers

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
