//
//  LoginItemManager.swift
//  AutoSwitcher
//
//  Thin wrapper around SMAppService (macOS 13+) so the user can toggle
//  "Launch at login" from Preferences. Under the hood this registers the
//  current .app bundle with the Service Management daemon — the same
//  mechanism used by RuSwitcher and any modern menu-bar utility.
//

import Foundation
import ServiceManagement

enum LoginItemManager {

    /// Whether autostart is currently enabled. Reading is cheap.
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Toggle autostart on or off. Returns whether the new state matches
    /// the request (errors are logged via Diag.log and otherwise swallowed).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard #available(macOS 13.0, *) else {
            Diag.log("Login item: macOS < 13, autostart unsupported")
            return false
        }
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    Diag.log("Login item: already enabled")
                    return true
                }
                try SMAppService.mainApp.register()
                Diag.log("Login item: registered")
            } else {
                try SMAppService.mainApp.unregister()
                Diag.log("Login item: unregistered")
            }
            return SMAppService.mainApp.status == (enabled ? .enabled : .notRegistered)
        } catch {
            Diag.log("Login item: error \(error)")
            return false
        }
    }
}
