//
//  AppIgnoreList.swift
//  AutoSwitcher
//
//  Phase 6: Check the frontmost application's bundle identifier against the
//  ignore list (terminals, code editors, password managers). The list lives
//  in UserDefaults so the user can edit it in Settings if we expose it.
//
//  Performance note: `NSWorkspace.frontmostApplication` is an XPC round-trip
//  and the check runs for EVERY keyboard/mouse event in the tap. We therefore
//  cache both the frontmost bundle id (refreshed via workspace activation
//  notifications) and the configured id set (refreshed on defaults changes).
//  The tap is attached to the main runloop, so reads and notification-driven
//  writes all happen on the main thread — no locking needed.
//

import AppKit

enum AppIgnoreList {

    private static var cachedFrontBundleID: String?
    private static var cachedIgnoredIDs: Set<String> = []
    private static var observing = false

    /// Call once from the main thread at app startup.
    static func startObserving() {
        guard !observing else { return }
        observing = true

        cachedFrontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        reloadIgnoredIDs()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            cachedFrontBundleID = app?.bundleIdentifier
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            reloadIgnoredIDs()
        }
    }

    private static func reloadIgnoredIDs() {
        let configured = UserDefaults.standard.stringArray(forKey: AppSettings.Keys.ignoredBundleIDs)
            ?? AppSettings.defaultIgnoredBundleIDs
        cachedIgnoredIDs = Set(configured)
    }

    static func isFrontmostAppIgnored() -> Bool {
        // Fallback for the (never expected) case where startObserving wasn't
        // called: fail open, i.e. don't ignore anything.
        guard observing else { return false }
        guard let bid = cachedFrontBundleID else { return false }
        return cachedIgnoredIDs.contains(bid)
    }
}
