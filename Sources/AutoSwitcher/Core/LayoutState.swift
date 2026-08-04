//
//  LayoutState.swift
//  AutoSwitcher
//
//  Publishes the currently selected keyboard layout so the menu-bar icon can
//  show a country flag that tracks the system input source in real time
//  (the YouType behaviour). We listen to the Carbon TIS distributed
//  notification, which fires on every input-source change regardless of who
//  triggered it — the user, the OS, or our own AutoCorrector.
//

import AppKit
import Combine

final class LayoutState: ObservableObject {

    @Published private(set) var current: KeyboardLayout?

    /// Briefly true right after an auto-correction — the menu-bar icon
    /// swaps to a "⇄" glyph for a moment so the user sees the app acted.
    @Published private(set) var correctionFlash = false

    private let layoutManager: LayoutManager
    private var flashResetWork: DispatchWorkItem?

    init(layoutManager: LayoutManager) {
        self.layoutManager = layoutManager
        self.current = layoutManager.current()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            forName: .autoSwitcherDidCorrect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.correctionFlash = true
            self.flashResetWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.correctionFlash = false }
            self.flashResetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }

        // Safety net for the notification race (see inputSourceChanged):
        // reconcile the flag with reality every few seconds so a missed or
        // premature notification can never leave a stale icon for long.
        let reconcile = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(reconcile, forMode: .common)
        self.reconcileTimer = reconcile
    }

    private var reconcileTimer: Timer?

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        reconcileTimer?.invalidate()
    }

    /// The TIS change notification can arrive BEFORE
    /// TISCopyCurrentKeyboardInputSource starts returning the new source
    /// (cross-process propagation is async). If we read too early we cache
    /// the OLD layout and no further notification ever corrects it — the
    /// menu-bar flag then shows the wrong language until the next switch.
    /// Re-reading a few times over ~half a second closes that window.
    @objc private func inputSourceChanged() {
        for delay in [0.0, 0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        let now = layoutManager.current()
        if now != current {
            current = now
        }
    }
}

// MARK: - Flag rendering for the status item

enum FlagIcon {

    private static var cache: [String: NSImage] = [:]

    /// A small colored flag image for the menu bar (rendered from the emoji
    /// flag glyph — crisp on retina, automatically matches system emoji art).
    static func image(for layout: KeyboardLayout) -> NSImage {
        let emoji: String
        switch layout {
        case .russian: emoji = "🇷🇺"
        case .english: emoji = "🇺🇸"
        }
        if let cached = cache[emoji] { return cached }

        let str = NSAttributedString(
            string: emoji,
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let textSize = str.size()
        let size = NSSize(width: ceil(textSize.width), height: 17)
        let image = NSImage(size: size, flipped: false) { rect in
            str.draw(at: NSPoint(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2
            ))
            return true
        }
        // Colored image — must NOT be a template or macOS flattens it to mono.
        image.isTemplate = false
        cache[emoji] = image
        return image
    }
}
