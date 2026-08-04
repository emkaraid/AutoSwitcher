//
//  PermissionsOnboardingWindow.swift
//  AutoSwitcher
//
//  A modern permissions walkthrough shown on first launch (and reachable
//  from the menu at any time). Each missing permission gets a card with a
//  live status indicator and a button that deep-links straight into the
//  right System Settings pane — no manual hunting.
//
//  The window floats above other apps so it can't get lost behind whatever
//  the user is working in (LSUIElement apps don't activate normally).
//

import AppKit
import SwiftUI

final class PermissionsWindowController {

    static let shared = PermissionsWindowController()

    private var window: NSWindow?

    private init() {}

    func show(permissions: PermissionsManager) {
        if window == nil {
            let root = PermissionsOnboardingView(
                onClose: { [weak self] in self?.close() }
            )
            .environmentObject(permissions)

            let hosting = NSHostingController(rootView: AnyView(root))
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.center()
            window = w
        }
        window?.title = L10n.shared.t("ob.windowTitle")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.orderOut(nil)
    }
}

// MARK: - SwiftUI content

private struct PermissionsOnboardingView: View {
    @EnvironmentObject var permissions: PermissionsManager
    @ObservedObject var l10n = L10n.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.top, 8)

            Text(l10n.t("ob.title"))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(l10n.t("ob.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            PermissionCard(
                icon: "figure.wave.circle.fill",
                title: l10n.t("perm.ax"),
                subtitle: l10n.t("ob.ax.desc"),
                granted: permissions.isAXTrusted,
                grantedLabel: l10n.t("ob.granted"),
                buttonLabel: l10n.t("perm.open"),
                action: { permissions.openAccessibilitySettings() }
            )

            PermissionCard(
                icon: "keyboard.circle.fill",
                title: l10n.t("perm.im"),
                subtitle: l10n.t("ob.im.desc"),
                granted: permissions.isInputMonitoringOK,
                grantedLabel: l10n.t("ob.granted"),
                buttonLabel: l10n.t("perm.open"),
                action: { permissions.openInputMonitoringSettings() }
            )

            if permissions.isTrusted {
                Label(l10n.t("ob.allSet"), systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 4) {
                    Text(l10n.t("ob.step"))
                    Text(l10n.t("ob.note"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            Button(l10n.t("ob.close"), action: onClose)
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 4)
        }
        .padding(28)
        .frame(width: 460)
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let granted: Bool
    let grantedLabel: String
    let buttonLabel: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(granted ? .green : .accentColor)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                Label(grantedLabel, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(buttonLabel, action: action)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(granted ? Color.green.opacity(0.35) : Color.primary.opacity(0.08),
                                lineWidth: 1)
                )
        )
    }
}
