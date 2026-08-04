//
//  AppDelegate.swift
//  AutoSwitcher
//
//  Owns long-lived singletons: PermissionsManager, KeyboardMonitor,
//  AutoCorrector, LayoutManager. Responsible for graceful start/stop and
//  for keeping the app alive as a pure menu-bar utility (LSUIElement).
//

import AppKit
import ApplicationServices
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    // MARK: - Singletons exposed to SwiftUI

    let permissionsManager = PermissionsManager()
    let layoutManager = LayoutManager()
    private(set) var autoCorrector: AutoCorrector!
    private(set) var keyboardMonitor: KeyboardMonitor!

    /// Publishes the active keyboard layout for the menu-bar flag icon.
    lazy var layoutState = LayoutState(layoutManager: layoutManager)

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The previous session's file is rotated to debug.log.prev by the
        // first Diag.log call of this process (see Diag.rotateOnce).
        Diag.log("=== AutoSwitcher launched ===")
        Diag.log("bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)")

        // Ensure the app is treated as an accessory (no Dock icon). The Info.plist
        // also sets LSUIElement=true, this is a defensive fallback.
        NSApp.setActivationPolicy(.accessory)

        // Build the engine. Order matters: AutoCorrector needs LayoutManager, the
        // KeyboardMonitor needs both the corrector and the settings.
        autoCorrector = AutoCorrector(layoutManager: layoutManager)
        keyboardMonitor = KeyboardMonitor(
            permissions: permissionsManager,
            autoCorrector: autoCorrector,
            layoutManager: layoutManager
        )

        // Warm the frontmost-app / ignore-list cache before the tap starts.
        AppIgnoreList.startObserving()

        // Kick off the two-permission probe (Accessibility + Input Monitoring).
        // The native system prompts will surface here on first launch; on
        // subsequent launches we just read the cached TCC decisions.
        permissionsManager.requestPermissionsIfNeeded()
        observeSettingsAndPermissions()
        startEngineIfReady()

        // If permissions are still missing, walk the user through them with
        // a proper onboarding window (deep links into System Settings)
        // instead of leaving them to hunt through panes manually.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if !self.permissionsManager.isTrusted {
                PermissionsWindowController.shared.show(permissions: self.permissionsManager)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboardMonitor?.stop()
    }

    // MARK: - Coordination

    /// Watch AppSettings.engineEnabled and permissions; start or stop the tap
    /// as needed so the user can flip the toggle without restarting the app.
    private func observeSettingsAndPermissions() {
        let defaults = UserDefaults.standard

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in
                self?.startEngineIfReady()
            }
            .store(in: &cancellables)

        permissionsManager.$isTrusted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.startEngineIfReady()
            }
            .store(in: &cancellables)

        // Temporary pause (menu: "Pause for 30 min / 1 h / until restart").
        PauseManager.shared.$pausedUntil
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.startEngineIfReady()
            }
            .store(in: &cancellables)

        // Input Monitoring permission only takes effect after a process
        // relaunch. As soon as we observe IM transition false → true while
        // we are running, automatically restart so the new process picks
        // it up — saves the user from a manual quit-and-reopen dance.
        // We give it a short delay to avoid restart-storms on launch and
        // skip the very first publish (which is just initial value=false).
        var seenInitial = false
        var hadIM = permissionsManager.isInputMonitoringOK
        permissionsManager.$isInputMonitoringOK
            .receive(on: RunLoop.main)
            .sink { [weak self] newVal in
                defer { seenInitial = true }
                guard seenInitial else { return }
                if newVal && !hadIM {
                    Diag.log("Input Monitoring just granted — auto-relaunching to apply")
                    hadIM = true
                    self?.relaunchSelf()
                } else {
                    hadIM = newVal
                }
            }
            .store(in: &cancellables)
    }

    /// Spawn a detached copy of ourselves, then exit. macOS LaunchServices
    /// will hand the new process the fresh TCC state for Input Monitoring.
    private func relaunchSelf() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private func startEngineIfReady() {
        let enabled = UserDefaults.standard.object(forKey: AppSettings.Keys.engineEnabled) as? Bool ?? true
        let paused = PauseManager.shared.isPaused
        let shouldRun = enabled && !paused
        // This fires on EVERY UserDefaults change (including the stats
        // counters after each correction) — log only actual transitions to
        // keep the diagnostics file readable.
        if shouldRun != keyboardMonitor.isRunning {
            let ax = AXIsProcessTrusted()
            let imOK = permissionsManager.isInputMonitoringOK
            Diag.log("startEngineIfReady — enabled=\(enabled) paused=\(paused) AX=\(ax) IM=\(imOK)")
        }
        if shouldRun {
            // Try to install the tap regardless of TCC reporting. If AX is
            // truly missing, CGEvent.tapCreate returns nil and we log that.
            keyboardMonitor.start()
        } else {
            keyboardMonitor.stop()
        }
    }
}
