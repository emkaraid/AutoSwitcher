//
//  MenuBarContentView.swift
//  AutoSwitcher
//
//  The popover-less menu shown when the user clicks the status item.
//  Kept intentionally lightweight: a toggle, permissions status, Settings
//  entry, and Quit.
//
//  Opening the Settings scene from an LSUIElement app is fiddly: the window
//  tends to appear BEHIND other apps' windows because a menu-bar-only app
//  never activates normally. SettingsWindowRaiser fixes that by activating
//  the app and force-raising the Settings window right after it is created.
//

import SwiftUI
import AppKit

struct MenuBarContentView: View {
    @Binding var engineEnabled: Bool
    let layoutManager: LayoutManager
    @ObservedObject var layoutState: LayoutState
    @EnvironmentObject var permissions: PermissionsManager
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var pause = PauseManager.shared
    @ObservedObject private var stats = StatsStore.shared

    /// The layout the manual menu action would switch TO: the opposite of
    /// the active one. When the active layout is neither EN nor RU we offer
    /// Russian first (the app's primary audience types Russian).
    private var switchTarget: KeyboardLayout {
        layoutState.current == .russian ? .english : .russian
    }

    private var resumeTitle: String {
        if pause.isPausedUntilRestart {
            return l10n.t("menu.resumeRestart")
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let until = pause.pausedUntil.map { formatter.string(from: $0) } ?? ""
        return l10n.t("menu.resume", until)
    }

    var body: some View {
        Toggle(isOn: $engineEnabled) {
            Text(l10n.t("menu.enable"))
        }
        .toggleStyle(.checkbox)

        Button(l10n.t("menu.switchTo",
                      l10n.t(switchTarget == .russian ? "layout.ru" : "layout.en"))) {
            layoutManager.switchTo(switchTarget)
        }

        // Temporary pause without touching the persistent enable toggle.
        if pause.isPaused {
            Button(resumeTitle) {
                pause.resume()
            }
        } else {
            Menu(l10n.t("menu.pause")) {
                Button(l10n.t("menu.pause30")) { pause.pause(for: 30 * 60) }
                Button(l10n.t("menu.pause1h")) { pause.pause(for: 60 * 60) }
                Button(l10n.t("menu.pauseRestart")) { pause.pauseUntilRestart() }
            }
        }

        Divider()

        Text("\(l10n.t("menu.statsToday")): \(stats.today) · \(l10n.t("menu.statsTotal")): \(stats.total)")

        if !permissions.isTrusted {
            Divider()
            Button(l10n.t("menu.permissions")) {
                PermissionsWindowController.shared.show(permissions: permissions)
            }
            Text(l10n.t("menu.permissionsHint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider()

        if #available(macOS 14, *) {
            SettingsMenuButton(title: l10n.t("menu.settings"))
        } else {
            Button(l10n.t("menu.settings")) {
                NSApp.activate(ignoringOtherApps: true)
                if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                SettingsWindowRaiser.raise()
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        Divider()

        Button(l10n.t("menu.checkUpdates")) {
            UpdateChecker.checkNow()
        }

        // Relaunching is necessary after granting Input Monitoring — macOS
        // only refreshes that permission at process startup. We launch a
        // detached copy of ourselves, then exit; the new process picks up
        // the freshly granted TCC entries.
        Button(l10n.t("menu.restart")) {
            relaunch()
        }

        Button(l10n.t("menu.quit")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        // Give Launch Services a moment to spawn the new process before we exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}

/// macOS 14+ path: the `openSettings` environment action is the only API
/// SwiftUI guarantees to work from a MenuBarExtra context.
@available(macOS 14.0, *)
private struct SettingsMenuButton: View {
    let title: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            SettingsWindowRaiser.raise()
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Brings the SwiftUI Settings window to the front of everything. An
/// LSUIElement app doesn't activate like a normal app, so without this the
/// window regularly opens BEHIND the current app and looks like it never
/// opened at all. We retry a few times because the window is created
/// asynchronously after the open action fires.
enum SettingsWindowRaiser {
    static func raise() {
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows
                where window.identifier?.rawValue.lowercased().contains("settings") == true
                   || window.identifier?.rawValue.lowercased().contains("preferences") == true {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
        }
    }
}
