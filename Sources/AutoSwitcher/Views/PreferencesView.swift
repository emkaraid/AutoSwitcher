//
//  PreferencesView.swift
//  AutoSwitcher
//
//  Phase 8: behaviour toggles. All values use @AppStorage so the engine
//  threads (which read UserDefaults directly) pick up changes instantly.
//

import SwiftUI
import AppKit

struct PreferencesView: View {
    @AppStorage(AppSettings.Keys.engineEnabled)         private var engineEnabled: Bool = true
    @AppStorage(AppSettings.Keys.smartUndoEnabled)      private var smartUndoEnabled: Bool = true
    @AppStorage(AppSettings.Keys.playSoundOnSwitch)     private var playSound: Bool = false
    @AppStorage(AppSettings.Keys.ignoreWordsWithDigits) private var ignoreDigits: Bool = true
    @AppStorage(AppSettings.Keys.launchAtLogin)         private var launchAtLogin: Bool = false
    @AppStorage(AppSettings.Keys.askBeforeAddToDict)    private var askBeforeAddToDict: Bool = true
    @AppStorage(AppSettings.Keys.optionTapEnabled)      private var optionTapEnabled: Bool = true
    @AppStorage(AppSettings.Keys.correctOnEnter)        private var correctOnEnter: Bool = false
    @AppStorage(AppSettings.Keys.convertSelectionEnabled) private var convertSelection: Bool = true
    @AppStorage(AppSettings.Keys.autoLearnEnabled)      private var autoLearn: Bool = true
    @AppStorage(AppSettings.Keys.verboseLogging)        private var verboseLogging: Bool = false

    @EnvironmentObject private var permissions: PermissionsManager
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Form {
            Section {
                Picker(l10n.t("prefs.language"), selection: $l10n.language) {
                    Text(l10n.t("lang.system")).tag("system")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                .pickerStyle(.menu)
            }

            Section {
                Toggle(l10n.t("prefs.enable"), isOn: $engineEnabled)
                Toggle(l10n.t("prefs.launchAtLogin"), isOn: $launchAtLogin)
                    // Use the macOS 13-compatible single-arg overload of
                    // onChange. The two-arg variant `(of:initial:_:)` only
                    // exists on macOS 14+, but our deployment target is 13.
                    .onChange(of: launchAtLogin) { newValue in
                        LoginItemManager.setEnabled(newValue)
                    }
                Toggle(l10n.t("prefs.smartUndo"), isOn: $smartUndoEnabled)
                Toggle(l10n.t("prefs.optionTap"), isOn: $optionTapEnabled)
                Toggle(l10n.t("prefs.convertSelection"), isOn: $convertSelection)
                Toggle(l10n.t("prefs.correctOnEnter"), isOn: $correctOnEnter)
                Toggle(l10n.t("prefs.askAdd"), isOn: $askBeforeAddToDict)
                Toggle(l10n.t("prefs.autoLearn"), isOn: $autoLearn)
                Toggle(l10n.t("prefs.playSound"), isOn: $playSound)
                Toggle(l10n.t("prefs.ignoreDigits"), isOn: $ignoreDigits)
            } header: {
                Text(l10n.t("prefs.behavior"))
            } footer: {
                Text(l10n.t("prefs.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(l10n.t("perm.section")) {
                permissionRow(
                    granted: permissions.isAXTrusted,
                    name: l10n.t("perm.ax"),
                    open: { permissions.openAccessibilitySettings() }
                )
                permissionRow(
                    granted: permissions.isInputMonitoringOK,
                    name: l10n.t("perm.im"),
                    open: { permissions.openInputMonitoringSettings() }
                )
                // Shown only while some app actually holds Secure Input —
                // it explains why corrections suddenly stopped (password
                // fields, sudo prompts, or an app that forgot to release it).
                if permissions.isSecureInputActive {
                    HStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text(l10n.t("perm.secure.on"))
                        Spacer()
                    }
                }
            }

            Section {
                Toggle(l10n.t("prefs.verboseLog"), isOn: $verboseLogging)
                HStack {
                    Button(l10n.t("prefs.openLog")) {
                        let url = URL(fileURLWithPath: Diag.path)
                        if !NSWorkspace.shared.open(url) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Spacer()
                }
            } header: {
                Text(l10n.t("prefs.diagnostics"))
            } footer: {
                Text(l10n.t("prefs.logFooter"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(granted: Bool, name: String, open: @escaping () -> Void) -> some View {
        HStack {
            Circle()
                .fill(granted ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text("\(name): \(l10n.t(granted ? "perm.granted" : "perm.required"))")
            Spacer()
            if !granted {
                Button(l10n.t("perm.open"), action: open)
            }
        }
    }
}
