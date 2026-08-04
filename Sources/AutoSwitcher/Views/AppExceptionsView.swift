//
//  AppExceptionsView.swift
//  AutoSwitcher
//
//  Settings tab for the app ignore list (terminals, IDEs, password
//  managers…). The engine already reloads the list live through the
//  UserDefaults observer in AppIgnoreList, so this view only needs to
//  read/write the `ignoredBundleIDs` array.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppExceptionsView: View {
    @ObservedObject private var l10n = L10n.shared

    @State private var bundleIDs: [String] = AppExceptionsView.load()
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("apps.title"))
                .font(.headline)
            Text(l10n.t("apps.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)

            List(selection: $selection) {
                ForEach(bundleIDs, id: \.self) { id in
                    AppRow(bundleID: id)
                        .tag(id)
                }
            }
            .listStyle(.bordered)

            HStack {
                Button(l10n.t("apps.add")) { addViaOpenPanel() }
                Button(l10n.t("apps.remove")) {
                    bundleIDs.removeAll { selection.contains($0) }
                    selection.removeAll()
                    persist()
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button(l10n.t("apps.reset")) {
                    bundleIDs = AppSettings.defaultIgnoredBundleIDs
                    selection.removeAll()
                    persist()
                }
            }
        }
        .padding(16)
        .onAppear { bundleIDs = AppExceptionsView.load() }
    }

    private static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: AppSettings.Keys.ignoredBundleIDs)
            ?? AppSettings.defaultIgnoredBundleIDs
    }

    private func persist() {
        UserDefaults.standard.set(bundleIDs, forKey: AppSettings.Keys.ignoredBundleIDs)
    }

    private func addViaOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            if !bundleIDs.contains(id) {
                bundleIDs.append(id)
            }
        }
        bundleIDs.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        persist()
    }
}

/// One row: app icon + display name when the app is installed, otherwise
/// just the raw bundle identifier.
private struct AppRow: View {
    let bundleID: String

    var body: some View {
        HStack(spacing: 8) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(FileManager.default.displayName(atPath: url.path))
                    Text(bundleID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 20, height: 20)
                Text(bundleID)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}
