//
//  WordChecker.swift
//  AutoSwitcher
//
//  Uses macOS's built-in NSSpellChecker (which already speaks English,
//  Russian and many other languages) to decide whether a candidate
//  "translation" is actually a real word in the target language.
//
//  Why this matters: the static heuristics in LayoutDetector can't catch
//  cases like `руддщ` (= "hello" typed in RU mode) — pure Cyrillic with
//  Russian vowels looks perfectly plausible in Russian. But the
//  translation "hello" is a known English word — a fact NSSpellChecker
//  can verify cheaply on the main thread.
//

import Foundation
import AppKit

enum WordChecker {

    /// Returns true if `word` is recognised by macOS's spell checker for
    /// the requested language. The check uses a fresh-init checker (cheap)
    /// and forces the language regardless of the user's current locale.
    static func isKnownWord(_ word: String, language: String) -> Bool {
        var trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip punctuation clinging to the word edges ("привет," / "hello;")
        // so the spell checker judges the word itself, not the punctuation.
        while let first = trimmed.first, !first.isLetter { trimmed.removeFirst() }
        while let last = trimmed.last, !last.isLetter { trimmed.removeLast() }
        guard trimmed.count >= 2 else { return false }

        // checkSpelling returns a range of length 0 when nothing is wrong.
        // Length > 0 means "this looks misspelled".
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(
            of: trimmed,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.length == 0
    }

    /// Convenience wrappers for the two languages we care about.
    static func isEnglish(_ word: String) -> Bool {
        return isKnownWord(word, language: "en")
    }

    static func isRussian(_ word: String) -> Bool {
        return isKnownWord(word, language: "ru")
    }
}
