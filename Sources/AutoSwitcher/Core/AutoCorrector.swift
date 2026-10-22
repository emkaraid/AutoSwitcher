//
//  AutoCorrector.swift
//  AutoSwitcher
//
//  Phase 5: Performs the "delete N chars → switch layout → retype" dance
//  using synthesized CGEvents. Posts events with a brief sleep between them
//  so the focused app has time to settle and we don't race ourselves.
//
//  Type-ahead: a correction takes ~0.1 s, and fast typists keep going. The
//  KeyboardMonitor swallows physical keystrokes while `isCorrecting` is set
//  and hands them back here; we replay them right after our own events, in
//  order, rendered in the layout we just switched to. Without this the
//  user's keys interleave with our backspaces and the text gets corrupted.
//

import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted (on main) after a correction finishes — drives the brief
    /// arrows animation of the menu-bar icon.
    static let autoSwitcherDidCorrect = Notification.Name("AutoSwitcherDidCorrect")
}

final class AutoCorrector {

    // While a correction is in flight we set this flag so the KeyboardMonitor
    // ignores its own synthesized keystrokes (we also tag them with a sentinel
    // user data on the events themselves as a belt-and-braces measure).
    // Written on the correction queue, read on the tap thread — always
    // accessed under `lock`.
    private var _isCorrecting = false
    private let lock = NSLock()

    var isCorrecting: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCorrecting
    }

    /// Sentinel user-data value used to mark events we post ourselves so we
    /// can ignore them when they come back through the system tap.
    static let syntheticEventUserData: Int64 = 0xA17C0_DE

    /// Marks the user's own keystrokes that we re-post after a correction.
    /// Unlike synthetic events the monitor DOES track these (buffer, last
    /// word) — they are real typing, just delivered a few ms late.
    static let replayEventUserData: Int64 = 0xA17C0_DF

    /// A keystroke swallowed during a correction, ready to be replayed.
    enum ReplayItem {
        case text(String)                  // a text key, already rendered for the target layout
        case key(CGKeyCode, CGEventFlags)  // shortcuts, Delete, arrows… — re-pressed by key code
    }

    /// Installed by KeyboardMonitor. Called on the main thread; returns —
    /// and clears — the keystrokes swallowed so far, rendered for `target`.
    var takeQueuedKeys: ((KeyboardLayout) -> [ReplayItem])?

    private let layoutManager: LayoutManager

    /// Records the last correction so SmartUndoManager can revert it.
    struct LastCorrection {
        let originalWrongText: String   // the word the user actually typed
        let originalTrailing: String    // the boundary they typed after it, as typed
        let correctedText: String       // what we typed instead (word + converted boundary)
        let fromLayout: KeyboardLayout  // layout active when user was typing
        let toLayout: KeyboardLayout    // layout we switched to
        let timestamp: Date
        /// True for user-initiated ⌥ conversions. Those must NOT go through
        /// the auto-revert paths (Backspace / ⌥ revert): toggling back is
        /// handled by converting again, and feeding manual toggles into the
        /// "add to Dictionary" flow would pollute the whitelist.
        let isManual: Bool
    }
    // Same cross-thread story as isCorrecting: written on the correction
    // queue, read on the tap thread when Backspace arrives.
    private var _lastCorrection: LastCorrection?

    var lastCorrection: LastCorrection? {
        lock.lock(); defer { lock.unlock() }
        return _lastCorrection
    }

    init(layoutManager: LayoutManager) {
        self.layoutManager = layoutManager
    }

    /// Run the correction sequence. `originalWrong` is the literal text the
    /// user typed and `originalTrailing` the boundary they typed after it
    /// (kept so a revert restores exactly what was typed); `corrected` is
    /// the rendition in the target layout. `trailingKey` (Return for
    /// correct-on-Enter) is re-pressed with its original modifiers after the
    /// corrected text — the caller ate the physical key event.
    /// Performed on a background queue to avoid blocking the event tap.
    /// Returns false when another correction is still running.
    @discardableResult
    func performCorrection(originalWrong: String,
                           originalTrailing: String = "",
                           corrected: String,
                           fromLayout: KeyboardLayout,
                           toLayout: KeyboardLayout,
                           playSound: Bool,
                           trailingKey: (code: CGKeyCode, flags: CGEventFlags)? = nil,
                           isManual: Bool = false) -> Bool {
        // Guard against re-entrancy.
        lock.lock()
        if _isCorrecting {
            lock.unlock()
            return false
        }
        _isCorrecting = true
        lock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            defer {
                self.replayQueuedKeysAndFinish(target: toLayout)
                Diag.log("correction finished")
            }

            Diag.log("correction starting — delete \(originalWrong.count), type \(corrected.count) unicode chars")

            // 1) Delete the wrong characters with backspaces.
            for _ in 0..<originalWrong.count {
                self.postKey(virtualKey: CGKeyCode(kVK_Delete), modifiers: [])
                Thread.sleep(forTimeInterval: 0.005)
            }
            Thread.sleep(forTimeInterval: 0.015)

            // 2) Switch the layout.
            let switched = self.layoutManager.switchTo(toLayout)
            Diag.log("switchTo(\(toLayout.rawValue)) returned \(switched)")
            Thread.sleep(forTimeInterval: 0.020)

            // 3) Re-type the corrected characters as a unicode string event.
            // Posting one unicode event per character is more reliable than
            // synthesizing virtual key codes (which depend on layout state).
            for ch in corrected {
                self.postUnicode(String(ch))
                Thread.sleep(forTimeInterval: 0.003)
            }

            // 3b) Press the eaten trailing key (Return for correct-on-Enter),
            // with its modifiers: ⇧⏎ must stay a newline, not "send".
            if let key = trailingKey {
                Thread.sleep(forTimeInterval: 0.01)
                self.postKey(virtualKey: key.code, modifiers: key.flags)
            }

            // 4) Remember this correction for Smart Undo — but NOT when a
            // trailing key (Enter) was re-pressed: the caret is then past a
            // newline (or the message is already sent), so a later revert
            // would backspace through unrelated text.
            if trailingKey == nil {
                let record = LastCorrection(
                    originalWrongText: originalWrong,
                    originalTrailing: originalTrailing,
                    correctedText: corrected,
                    fromLayout: fromLayout,
                    toLayout: toLayout,
                    timestamp: Date(),
                    isManual: isManual
                )
                self.lock.lock()
                self._lastCorrection = record
                self.lock.unlock()
            }

            // 5) Stats + icon animation + optional sound. Manual ⌥
            // conversions stay out of the counters — toggling a word back
            // and forth must not inflate "corrected today".
            if !isManual {
                StatsStore.shared.recordCorrection()
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .autoSwitcherDidCorrect, object: nil)
                if playSound {
                    NSSound(named: NSSound.Name("Tink"))?.play()
                }
            }
        }
        return true
    }

    /// Revert the last correction: delete the corrected text, switch layout
    /// back, retype exactly what the user typed (word AND its boundary —
    /// otherwise the space after the word silently disappears).
    /// Returns false when nothing could be reverted.
    @discardableResult
    func revertLastCorrection() -> Bool {
        guard let last = lastCorrection else { return false }

        // Same re-entrancy guard.
        lock.lock()
        if _isCorrecting {
            lock.unlock()
            return false
        }
        _isCorrecting = true
        lock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            defer {
                self.replayQueuedKeysAndFinish(target: last.fromLayout)
            }

            for _ in 0..<last.correctedText.count {
                self.postKey(virtualKey: CGKeyCode(kVK_Delete), modifiers: [])
                Thread.sleep(forTimeInterval: 0.005)
            }
            Thread.sleep(forTimeInterval: 0.015)

            _ = self.layoutManager.switchTo(last.fromLayout)
            Thread.sleep(forTimeInterval: 0.020)

            for ch in last.originalWrongText + last.originalTrailing {
                self.postUnicode(String(ch))
                Thread.sleep(forTimeInterval: 0.003)
            }

            self.lock.lock()
            self._lastCorrection = nil
            self.lock.unlock()

            // The correction turned out to be unwanted — remove it from the
            // usefulness counters.
            StatsStore.shared.recordRevert()
        }
        return true
    }

    // MARK: - Type-ahead replay

    /// Hand-off protocol with the monitor: under `main.sync` (the tap runs
    /// on main, so this is atomic with respect to it) take the swallowed
    /// keys; if there are none, clear `isCorrecting` in the same block — no
    /// keystroke can slip between "queue empty" and "flag cleared". Keys
    /// pressed while we replay are swallowed too and picked up by the next
    /// round, which preserves their order.
    private func replayQueuedKeysAndFinish(target: KeyboardLayout) {
        let maxRounds = 20
        for round in 1...maxRounds {
            let isLastRound = round == maxRounds
            var items: [ReplayItem] = []
            DispatchQueue.main.sync {
                items = self.takeQueuedKeys?(target) ?? []
                if items.isEmpty || isLastRound {
                    self.lock.lock()
                    self._isCorrecting = false
                    self.lock.unlock()
                }
            }
            for item in items {
                switch item {
                case .text(let text):
                    postUnicode(text, tag: Self.replayEventUserData)
                case .key(let code, let flags):
                    postKey(virtualKey: code, modifiers: flags, tag: Self.replayEventUserData)
                }
                Thread.sleep(forTimeInterval: 0.003)
            }
            if items.isEmpty || isLastRound { return }
            if round == 1 {
                Diag.log("replayed \(items.count) key(s) typed during the correction")
            }
            // Let the replayed events clear our own tap before checking again.
            Thread.sleep(forTimeInterval: 0.010)
        }
    }

    // MARK: - Low-level CGEvent helpers

    private func postKey(virtualKey: CGKeyCode, modifiers: CGEventFlags,
                         tag: Int64 = AutoCorrector.syntheticEventUserData) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true) {
            down.flags = modifiers
            down.setIntegerValueField(.eventSourceUserData, value: tag)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) {
            up.flags = modifiers
            up.setIntegerValueField(.eventSourceUserData, value: tag)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ string: String,
                             tag: Int64 = AutoCorrector.syntheticEventUserData) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        // IMPORTANT: keyboardSetUnicodeString does not strictly guarantee that
        // the source bytes are copied before the call returns — in practice it
        // sometimes holds the pointer alive. If we let the Swift Array fall
        // out of scope (end of withUnsafeBufferPointer closure) before .post()
        // runs, the pointer becomes dangling and the next post() invocation
        // can segfault in the kernel-side input synthesis path.
        //
        // The user hit exactly this crash on the "ktq → лей" correction.
        //
        // Fix: keep the utf16 array alive across .post() by doing the WHOLE
        // sequence (setUnicode + post) inside the closure scope. We also use
        // a separate fresh array for the up-event so its pointer also stays
        // valid for the duration of its .post() call.
        let utf16Down = Array(string.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.setIntegerValueField(.eventSourceUserData, value: tag)
            utf16Down.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: utf16Down.count, unicodeString: buf.baseAddress)
                down.post(tap: .cghidEventTap)
            }
        }
        let utf16Up = Array(string.utf16)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.setIntegerValueField(.eventSourceUserData, value: tag)
            utf16Up.withUnsafeBufferPointer { buf in
                up.keyboardSetUnicodeString(stringLength: utf16Up.count, unicodeString: buf.baseAddress)
                up.post(tap: .cghidEventTap)
            }
        }
        // Keep the arrays alive past the loop iteration explicitly. Swift's
        // optimizer can otherwise release the storage right after the closure.
        _ = utf16Down
        _ = utf16Up
    }
}
