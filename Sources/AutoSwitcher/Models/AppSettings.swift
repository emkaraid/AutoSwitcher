//
//  AppSettings.swift
//  AutoSwitcher
//
//  Central place for UserDefaults keys and persisted preferences. SwiftUI
//  views read individual values through @AppStorage; non-SwiftUI code reads
//  via UserDefaults.standard with the same key constants.
//

import Foundation

enum AppSettings {

    /// All UserDefaults keys live here so we have a single source of truth
    /// shared between the SwiftUI layer and the engine threads.
    enum Keys {
        static let engineEnabled        = "engineEnabled"
        static let whitelistWords       = "whitelistWords"
        static let smartUndoEnabled     = "smartUndoEnabled"
        static let playSoundOnSwitch    = "playSoundOnSwitch"
        static let ignoreWordsWithDigits = "ignoreWordsWithDigits"
        static let ignoredBundleIDs     = "ignoredBundleIDs"
        static let launchAtLogin        = "launchAtLogin"
        static let askBeforeAddToDict   = "askBeforeAddToDict"
        static let appLanguage          = "appLanguage"   // "system" | "en" | "ru"
        static let optionTapEnabled     = "optionTapEnabled"
        static let correctOnEnter       = "correctOnEnter"
        static let convertSelectionEnabled = "convertSelectionEnabled"
        static let autoLearnEnabled     = "autoLearnEnabled"
        static let verboseLogging       = "verboseLogging"
        static let statsDay             = "statsDay"
        static let statsToday           = "statsToday"
        static let statsTotal           = "statsTotal"
    }

    /// Default app bundle identifiers that should never be intercepted.
    /// Users can extend this list via the Settings UI; the saved value
    /// overrides this default when present.
    static let defaultIgnoredBundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.goland",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.rider",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7"
    ]

    /// Register one-time defaults so first-launch reads return sensible values.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.engineEnabled: true,
            // Off by default: a Backspace right after a correction is just as
            // often "delete that space / fix the comma" as "undo", and an
            // unwanted revert is worse than none. ⌥ tap is the explicit undo.
            Keys.smartUndoEnabled: false,
            Keys.playSoundOnSwitch: false,
            Keys.ignoreWordsWithDigits: true,
            Keys.whitelistWords: [String](),
            Keys.ignoredBundleIDs: defaultIgnoredBundleIDs,
            Keys.launchAtLogin: false,
            Keys.askBeforeAddToDict: true,
            Keys.appLanguage: "system",
            Keys.optionTapEnabled: true,
            Keys.correctOnEnter: false,
            Keys.convertSelectionEnabled: true,
            // Off by default: two accidental reverts (even far apart) must not
            // silently put a word in the Dictionary forever.
            Keys.autoLearnEnabled: false,
            Keys.verboseLogging: false
        ])
    }
}

/// Shared helper for the user's exception-word list. Used by the Smart Undo
/// toast, the auto-learn path and the Dictionary settings tab so all writers
/// share one dedupe/sort policy.
enum Whitelist {
    static func add(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = UserDefaults.standard.stringArray(forKey: AppSettings.Keys.whitelistWords) ?? []
        if !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            list.append(trimmed)
            list.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            UserDefaults.standard.set(list, forKey: AppSettings.Keys.whitelistWords)
            Diag.logSensitive("Whitelist: added '\(trimmed)'")
        }
    }
}
