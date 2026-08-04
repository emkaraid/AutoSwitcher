//
//  AutoCorrector.swift
//  AutoSwitcher
//
//  Phase 5: Performs the "delete N chars → switch layout → retype" dance
//  using synthesized CGEvents. Posts events with a brief sleep between them
//  so the focused app has time to settle and we don't race ourselves.
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

    private let layoutManager: LayoutManager

    /// Records the last correction so SmartUndoManager can revert it.
    struct LastCorrection {
        let originalWrongText: String   // what the user actually typed
        let correctedText: String       // what we typed instead
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
    /// user typed; `corrected` is the rendition in the target layout.
    /// `trailingKey` (e.g. Return for correct-on-Enter) is pressed after the
    /// corrected text is retyped — the caller ate the physical key event.
    /// Performed on a background queue to avoid blocking the event tap.
    func performCorrection(originalWrong: String,
                           corrected: String,
                           fromLayout: KeyboardLayout,
                           toLayout: KeyboardLayout,
                           playSound: Bool,
                           trailingKey: CGKeyCode? = nil,
                           isManual: Bool = false) {
        // Guard against re-entrancy.
        lock.lock()
        if _isCorrecting {
            lock.unlock()
            return
        }
        _isCorrecting = true
        lock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self._isCorrecting = false
                self.lock.unlock()
                Diag.log("correction finished")
            }

            Diag.log("correction starting — delete \(originalWrong.count), type \(corrected.count) unicode chars")

            // 1) Delete the wrong characters with backspaces.
            let count = originalWrong.count
            for _ in 0..<count {
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

            // 3b) Press the eaten trailing key (Return for correct-on-Enter).
            if let key = trailingKey {
                Thread.sleep(forTimeInterval: 0.01)
                self.postKey(virtualKey: key, modifiers: [])
            }

            // 4) Remember this correction for Smart Undo — but NOT when a
            // trailing key (Enter) was re-pressed: the caret is then past a
            // newline (or the message is already sent), so a later revert
            // would backspace through unrelated text.
            if trailingKey == nil {
                let record = LastCorrection(
                    originalWrongText: originalWrong,
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
    }

    /// Revert the last correction: delete the corrected text, switch layout
    /// back, type the original wrong text. Called by SmartUndoManager.
    func revertLastCorrection() {
        guard let last = lastCorrection else { return }

        // Same re-entrancy guard.
        lock.lock()
        if _isCorrecting {
            lock.unlock()
            return
        }
        _isCorrecting = true
        lock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self._isCorrecting = false
                self.lock.unlock()
            }

            for _ in 0..<last.correctedText.count {
                self.postKey(virtualKey: CGKeyCode(kVK_Delete), modifiers: [])
                Thread.sleep(forTimeInterval: 0.005)
            }
            Thread.sleep(forTimeInterval: 0.015)

            _ = self.layoutManager.switchTo(last.fromLayout)
            Thread.sleep(forTimeInterval: 0.020)

            for ch in last.originalWrongText {
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
    }

    // MARK: - Low-level CGEvent helpers

    private func postKey(virtualKey: CGKeyCode, modifiers: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true) {
            down.flags = modifiers
            down.setIntegerValueField(.eventSourceUserData, value: AutoCorrector.syntheticEventUserData)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) {
            up.flags = modifiers
            up.setIntegerValueField(.eventSourceUserData, value: AutoCorrector.syntheticEventUserData)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postUnicode(_ string: String) {
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
            down.setIntegerValueField(.eventSourceUserData, value: AutoCorrector.syntheticEventUserData)
            utf16Down.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: utf16Down.count, unicodeString: buf.baseAddress)
                down.post(tap: .cghidEventTap)
            }
        }
        let utf16Up = Array(string.utf16)
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.setIntegerValueField(.eventSourceUserData, value: AutoCorrector.syntheticEventUserData)
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
