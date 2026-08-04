//
//  UpdateChecker.swift
//  AutoSwitcher
//
//  Manual "Check for Updates…" from the menu. One GET to the GitHub
//  Releases API, a version compare, and an alert with a Download button
//  that opens the releases page in the browser.
//
//  Privacy note: this is the ONLY network request the app can make, and it
//  happens exclusively when the user clicks the menu item — never in the
//  background.
//

import AppKit
import Foundation

enum UpdateChecker {

    static let apiURL = URL(string: "https://api.github.com/repos/emkaraid/AutoSwitcher/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/emkaraid/AutoSwitcher/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Kick off the check; all UI happens back on the main thread.
    static func checkNow() {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            var outcome: Outcome = .error
            if error == nil,
               let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                outcome = isNewer(latest, than: currentVersion)
                    ? .updateAvailable(latest)
                    : .upToDate
            }
            DispatchQueue.main.async { present(outcome) }
        }.resume()
    }

    /// Numeric dotted-version compare: returns true when `candidate` is
    /// strictly newer than `current` ("1.10.0" > "1.9.1").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - UI

    private enum Outcome {
        case updateAvailable(String)
        case upToDate
        case error
    }

    private static func present(_ outcome: Outcome) {
        let l10n = L10n.shared
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch outcome {
        case .updateAvailable(let version):
            Diag.log("update check: \(version) available (current \(currentVersion))")
            alert.messageText = l10n.t("upd.available", version)
            alert.informativeText = l10n.t("upd.availableInfo", currentVersion)
            alert.addButton(withTitle: l10n.t("upd.download"))
            alert.addButton(withTitle: l10n.t("upd.later"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releasesPage)
            }
        case .upToDate:
            Diag.log("update check: up to date (\(currentVersion))")
            alert.messageText = l10n.t("upd.latest")
            alert.informativeText = l10n.t("upd.latestInfo", currentVersion)
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .error:
            Diag.log("update check failed")
            alert.alertStyle = .warning
            alert.messageText = l10n.t("upd.error")
            alert.informativeText = l10n.t("upd.errorInfo")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
