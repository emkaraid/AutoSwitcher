//
//  SmartUndoManager.swift
//  AutoSwitcher
//
//  Phase 8: If the user hits Backspace within 2 seconds of an auto-correction,
//  revert: delete the corrected word, switch layout back, retype the original
//  text the user actually pressed. Also tracks a short "do not auto-correct"
//  memory so we don't immediately re-correct the same word.
//

import Foundation

final class SmartUndoManager {

    private let window: TimeInterval = 2.0
    private let lock = NSLock()
    private var recentlyRevertedWords: [String: Date] = [:]
    private let recentMemory: TimeInterval = 30

    /// Should the next backspace, posted by the user, be eaten and translated
    /// into a "revert last correction"? Looks at the corrector's last entry.
    func shouldHandleBackspace(corrector: AutoCorrector) -> Bool {
        guard let last = corrector.lastCorrection else { return false }
        return Date().timeIntervalSince(last.timestamp) <= window
    }

    /// Record a word that was just reverted so the engine knows not to
    /// re-correct it on the next keystroke.
    func remember(word: String) {
        lock.lock(); defer { lock.unlock() }
        recentlyRevertedWords[word] = Date()
        // Garbage-collect old entries.
        let cutoff = Date().addingTimeInterval(-recentMemory)
        recentlyRevertedWords = recentlyRevertedWords.filter { $0.value > cutoff }
    }

    func isRecentlyReverted(_ word: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let when = recentlyRevertedWords[word] else { return false }
        return Date().timeIntervalSince(when) <= recentMemory
    }

    // MARK: - Auto-learn

    /// Per-session revert tally, case-insensitive. When the same word is
    /// reverted twice the engine auto-adds it to the Dictionary (if the
    /// auto-learn preference is on) instead of asking again and again.
    private var revertCounts: [String: Int] = [:]

    /// Record one more revert of `word` and return the running count.
    func registerRevert(word: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let key = word.lowercased()
        let count = (revertCounts[key] ?? 0) + 1
        revertCounts[key] = count
        return count
    }
}
