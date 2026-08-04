//
//  SettingsView.swift
//  AutoSwitcher
//
//  Settings scene with two tabs:
//    - General: behavior toggles, language picker, permissions status.
//    - Dictionary: user whitelist of words that must never be auto-corrected.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        TabView {
            PreferencesView()
                .tabItem { Label(l10n.t("tab.general"), systemImage: "gear") }

            DictionaryView()
                .tabItem { Label(l10n.t("tab.dictionary"), systemImage: "book.closed") }

            AppExceptionsView()
                .tabItem { Label(l10n.t("tab.apps"), systemImage: "app.badge.checkmark") }
        }
        .frame(width: 540, height: 560)
    }
}
