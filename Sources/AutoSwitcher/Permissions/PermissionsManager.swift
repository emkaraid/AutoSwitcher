//
//  PermissionsManager.swift
//  AutoSwitcher
//
//  macOS-TCC handling for the two permissions that CGEventTap needs.
//
//  Lesson learned the hard way (and confirmed by RuSwitcher / Caramba and
//  Apple's own docs since macOS 10.15 Catalina): a CGEventTap that wants
//  to *receive* keystrokes needs the **Input Monitoring** TCC bucket.
//  Accessibility on its own is NOT enough — `CGEvent.tapCreate` will still
//  return a valid mach port, but no events ever flow through it.
//  Accessibility is required separately for *modifying* (posting) events.
//
//  So we track BOTH:
//   - isAXTrusted          → AXIsProcessTrusted()                (Accessibility)
//   - isInputMonitoringOK  → IOHIDCheckAccess(.listenEvent)      (Input Monitoring)
//
//  We also poll Secure Input so the engine can pause when password fields
//  / lock screen / sudo prompts grab the keyboard.
//

import AppKit
import ApplicationServices
import Carbon
import Combine
import IOKit
import IOKit.hid

final class PermissionsManager: ObservableObject {

    @Published private(set) var isAXTrusted: Bool = false
    @Published private(set) var isInputMonitoringOK: Bool = false
    @Published private(set) var isSecureInputActive: Bool = false

    /// True only when BOTH AX and Input Monitoring are granted.
    /// The KeyboardMonitor / AppDelegate observe this single composite flag.
    @Published private(set) var isTrusted: Bool = false

    private var pollTimer: Timer?

    init() {
        AppSettings.registerDefaults()
        let ax = AXIsProcessTrusted()
        let im = readInputMonitoring()
        Diag.log("PermissionsManager init — AX=\(ax)  InputMonitoring=\(im)")
        self.isAXTrusted = ax
        self.isInputMonitoringOK = im
        self.isTrusted = ax && im
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Initial prompt

    /// Called once from AppDelegate.applicationDidFinishLaunching.
    /// Surfaces the native system prompts for both AX and Input Monitoring
    /// if either is missing; falls back to our own NSAlert that opens the
    /// right Settings panel directly.
    func requestPermissionsIfNeeded() {
        // 1) Accessibility — passing `kAXTrustedCheckOptionPrompt` causes
        //    macOS to display its native AX prompt the first time only.
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options: CFDictionary = [promptKey: true] as CFDictionary
        let axNow = AXIsProcessTrustedWithOptions(options)
        Diag.log("AX after prompt request = \(axNow)")

        // 2) Input Monitoring — IOHIDRequestAccess shows the native prompt
        //    the first time, or silently returns the cached decision after.
        let imNow = requestInputMonitoring()
        Diag.log("InputMonitoring after request = \(imNow)")

        // No NSAlert fallback here anymore — AppDelegate shows the
        // PermissionsOnboardingWindow when anything is missing, with direct
        // deep links into the right System Settings panes.
        DispatchQueue.main.async { [weak self] in
            self?.update(ax: axNow, im: imNow)
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Polling

    private var pollTick = 0

    private func startPolling() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pollTick += 1

            // Secure Input is a cheap in-process check — every tick.
            let secure = Bool(IsSecureEventInputEnabled())

            // The TCC checks are cross-process IPC to tccd. While waiting
            // for the user to grant permissions we poll every second for
            // snappy onboarding feedback; once everything is granted a 5 s
            // cadence is plenty (revocation is rare) and stops the constant
            // 1 Hz IPC churn that showed up in the unified log.
            var ax = self.isAXTrusted
            var im = self.isInputMonitoringOK
            if !self.isTrusted || self.pollTick % 5 == 0 {
                ax = AXIsProcessTrusted()
                im = self.readInputMonitoring()
            }

            DispatchQueue.main.async {
                self.update(ax: ax, im: im)
                if self.isSecureInputActive != secure {
                    self.isSecureInputActive = secure
                }
            }
        }
        // Add to the main runloop in common modes so the timer still fires
        // while modal panels (open/save dialogs, the menu bar dropdown) are up.
        RunLoop.main.add(timer, forMode: .common)
        self.pollTimer = timer
    }

    private func update(ax: Bool, im: Bool) {
        if isAXTrusted != ax {
            Diag.log("Accessibility trust changed → \(ax)")
            isAXTrusted = ax
        }
        if isInputMonitoringOK != im {
            Diag.log("Input Monitoring access changed → \(im)")
            isInputMonitoringOK = im
        }
        let composite = ax && im
        if isTrusted != composite {
            Diag.log("composite isTrusted → \(composite)")
            isTrusted = composite
        }
    }

    // MARK: - IOKit Input Monitoring bridge

    /// Synchronously checks Input Monitoring without prompting.
    private func readInputMonitoring() -> Bool {
        if #available(macOS 10.15, *) {
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
        return true
    }

    /// Shows the system prompt if Input Monitoring hasn't been decided yet,
    /// then returns the resulting state. macOS only prompts the FIRST time
    /// per binary identity — afterwards it just returns the cached answer.
    @discardableResult
    private func requestInputMonitoring() -> Bool {
        if #available(macOS 10.15, *) {
            return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        return true
    }

}
