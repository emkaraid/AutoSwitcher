//
//  AutoSwitcherApp.swift
//  AutoSwitcher
//
//  Entry point: a menu-bar-only SwiftUI app (LSUIElement) that wires up the
//  AppDelegate, exposes a MenuBarExtra status item, and provides a Settings
//  scene with General + Dictionary tabs.
//
//  The status-item label shows the flag of the ACTIVE keyboard layout
//  (🇺🇸 / 🇷🇺), tracking system input-source changes live — like YouType.
//  When the engine is off (or the layout is neither EN nor RU) it falls
//  back to a monochrome keyboard glyph.
//

import SwiftUI

@main
struct AutoSwitcherApp: App {
    // Bridge between SwiftUI and the AppKit lifecycle so we can manage the
    // event tap, permissions, sound playback and other singletons cleanly.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Persistent runtime toggle. The actual interception engine reads this
    // through AppSettings so the menu-bar toggle, accessibility prompts and
    // background thread stay loosely coupled.
    @AppStorage(AppSettings.Keys.engineEnabled) private var engineEnabled: Bool = true

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(engineEnabled: $engineEnabled,
                               layoutManager: appDelegate.layoutManager,
                               layoutState: appDelegate.layoutState)
                .environmentObject(appDelegate.permissionsManager)
        } label: {
            MenuBarFlagLabel(layoutState: appDelegate.layoutState,
                             engineEnabled: engineEnabled)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.permissionsManager)
        }
    }
}

/// Status-item label: colored layout flag while the engine runs, a pause
/// glyph while temporarily paused, a brief "⇄" flash right after an
/// auto-correction, and a dimmed keyboard outline when switched off.
private struct MenuBarFlagLabel: View {
    @ObservedObject var layoutState: LayoutState
    @ObservedObject private var pause = PauseManager.shared
    let engineEnabled: Bool

    var body: some View {
        if pause.isPaused {
            Image(systemName: "pause.circle")
        } else if layoutState.correctionFlash {
            Image(systemName: "arrow.left.arrow.right")
        } else if engineEnabled, let layout = layoutState.current {
            Image(nsImage: FlagIcon.image(for: layout))
        } else {
            Image(systemName: engineEnabled ? "keyboard.fill" : "keyboard")
        }
    }
}
