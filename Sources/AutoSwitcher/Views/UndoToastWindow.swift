//
//  UndoToastWindow.swift
//  AutoSwitcher
//
//  Tiny non-modal floating panel shown right after Smart Undo: lets the
//  user decide whether the just-reverted word should be permanently added
//  to the Dictionary (whitelist) so AutoSwitcher never corrects it again.
//
//  Behaviour mirrors what Caramba Switcher does after an undo — a small
//  unobtrusive toast in the lower-right corner that auto-dismisses after
//  a few seconds if you ignore it.
//

import AppKit
import SwiftUI

final class UndoToastWindow {

    static let shared = UndoToastWindow()

    private var panel: NSPanel?
    private var autoDismissTimer: Timer?

    private init() {}

    /// Show the toast for a freshly reverted word. Safe to call from any
    /// thread — internally hops to main if needed. Calling it again while
    /// a previous toast is still on screen replaces the content.
    func show(originalWord: String) {
        if Thread.isMainThread {
            showOnMain(originalWord: originalWord)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showOnMain(originalWord: originalWord)
            }
        }
    }

    /// Confirmation toast for auto-learn: the word was ALREADY added to the
    /// Dictionary automatically (second revert), just tell the user.
    func showAutoAdded(word: String) {
        if Thread.isMainThread {
            showAutoAddedOnMain(word: word)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showAutoAddedOnMain(word: word)
            }
        }
    }

    private func showOnMain(originalWord: String) {
        // Respect the user preference.
        let askEnabled = UserDefaults.standard.object(forKey: AppSettings.Keys.askBeforeAddToDict) as? Bool ?? true
        guard askEnabled else { return }

        let panel = ensurePanel()
        panel.contentView = NSHostingView(rootView: ToastContent(word: originalWord, onAdd: { [weak self] in
            Whitelist.add(originalWord)
            self?.dismiss()
        }, onDismiss: { [weak self] in
            self?.dismiss()
        }, onHover: { [weak self] hovering in
            self?.hoverChanged(hovering)
        }))
        positionPanel(panel)
        panel.orderFrontRegardless()
        scheduleDismiss(after: 10.0)
    }

    private func showAutoAddedOnMain(word: String) {
        let panel = ensurePanel()
        panel.contentView = NSHostingView(rootView: AutoAddedContent(word: word, onDismiss: { [weak self] in
            self?.dismiss()
        }, onHover: { [weak self] hovering in
            self?.hoverChanged(hovering)
        }))
        positionPanel(panel)
        panel.orderFrontRegardless()
        scheduleDismiss(after: 5.0)
    }

    private func scheduleDismiss(after interval: TimeInterval) {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss() }
        }
    }

    /// While the cursor is over the toast the user is reading it — freeze
    /// the auto-dismiss; restart a short grace period on exit.
    private func hoverChanged(_ hovering: Bool) {
        if hovering {
            autoDismissTimer?.invalidate()
            autoDismissTimer = nil
        } else {
            scheduleDismiss(after: 3.0)
        }
    }

    private func dismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 86),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.panel = p
        return p
    }

    /// Park the panel in the bottom-right corner of the main screen.
    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 24
        let frame = panel.frame
        let x = screen.visibleFrame.maxX - frame.width - margin
        let y = screen.visibleFrame.minY + margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Toast SwiftUI content

private struct ToastContent: View {
    let word: String
    let onAdd: () -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 16, y: 4)

            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.shared.t("toast.reverted", word))
                        .font(.system(size: 13, weight: .semibold))
                    Text(L10n.shared.t("toast.question"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button(L10n.shared.t("toast.add"), action: onAdd)
                        .controlSize(.small)
                        .keyboardShortcut("a", modifiers: [.command])
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
        }
        .frame(width: 320, height: 86)
        .onHover { onHover($0) }
    }
}

/// Slim confirmation shown when auto-learn added the word by itself.
private struct AutoAddedContent: View {
    let word: String
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 16, y: 4)

            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
                Text(L10n.shared.t("toast.autoAdded", word))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
        }
        .frame(width: 320, height: 86)
        .onHover { onHover($0) }
    }
}
