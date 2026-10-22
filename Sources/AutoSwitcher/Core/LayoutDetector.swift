//
//  LayoutDetector.swift
//  AutoSwitcher
//
//  Phase 4: Heuristics for detecting "wrong layout" typing between
//  US English (QWERTY) and Russian (ЙЦУКЕН).
//
//  Strategy:
//   1. Maintain a character-level mapping between the two physical key
//      positions (ё==`, q==й, etc.).
//   2. When the user finishes a "word" (whitespace, punctuation, etc.) we
//      look at the previous run and decide whether it is suspicious in the
//      current layout but plausible in the other one.
//   3. Suspicion heuristics:
//        - Contains characters that cannot legally appear in the *current*
//          layout's alphabet (e.g. Cyrillic letter while in English mode).
//        - Has impossibly few vowels for its length (catches "ghbdtn" =
//          привет, "ckj;yj" = сложно, etc.).
//        - Common consonant-only clusters indicate a wrong-layout typing.
//

import Foundation

struct LayoutDetector {

    // MARK: - Mappings

    /// Character at the same physical key in the EN ↔ RU layouts.
    ///
    /// The live table is built at runtime from the layouts the user really
    /// has enabled (LayoutManager.refreshKeyMapIfNeeded) — Apple "Russian"
    /// and "Russian – PC" disagree on punctuation and on ё (on the Mac
    /// layout `?` stays `?`, the comma is ⇧6, ё sits on `\`).
    ///
    /// Until then (and if building fails) this fallback is used: letters
    /// plus the punctuation keys that carry the SAME letters in every
    /// ЙЦУКЕН variant. Layout-specific punctuation is deliberately absent —
    /// an absent entry passes through unchanged, a wrong one corrupts text.
    private static let fallbackEnToRu: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н",
        "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р",
        "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т",
        "m": "ь", ",": "б", ".": "ю",
        "Q": "Й", "W": "Ц", "E": "У", "R": "К", "T": "Е", "Y": "Н",
        "U": "Г", "I": "Ш", "O": "Щ", "P": "З", "{": "Х", "}": "Ъ",
        "A": "Ф", "S": "Ы", "D": "В", "F": "А", "G": "П", "H": "Р",
        "J": "О", "K": "Л", "L": "Д", ":": "Ж", "\"": "Э",
        "Z": "Я", "X": "Ч", "C": "С", "V": "М", "B": "И", "N": "Т",
        "M": "Ь", "<": "Б", ">": "Ю"
    ]

    // Read from the tap (main) and from SelectionConverter (background),
    // written from main — guarded by `mapLock`.
    private static let mapLock = NSLock()
    private static var liveEnToRu: [Character: Character] = fallbackEnToRu
    private static var liveRuToEn: [Character: Character] = {
        var dict: [Character: Character] = [:]
        for (k, v) in fallbackEnToRu { dict[v] = k }
        return dict
    }()

    private static var enToRu: [Character: Character] {
        mapLock.lock(); defer { mapLock.unlock() }
        return liveEnToRu
    }

    private static var ruToEn: [Character: Character] {
        mapLock.lock(); defer { mapLock.unlock() }
        return liveRuToEn
    }

    /// Install a table derived from the real layouts. `pairs` is ordered
    /// (unshifted before shifted); the first pair wins on any collision so
    /// the result is deterministic.
    static func installKeyMap(_ pairs: [(Character, Character)]) {
        var forward: [Character: Character] = [:]
        var backward: [Character: Character] = [:]
        for (en, ru) in pairs {
            if forward[en] == nil { forward[en] = ru }
            if backward[ru] == nil { backward[ru] = en }
        }
        mapLock.lock()
        liveEnToRu = forward
        liveRuToEn = backward
        mapLock.unlock()
    }

    private static let russianVowels: Set<Character> = Set("аеёиоуыэюяАЕЁИОУЫЭЮЯ")
    private static let englishVowels: Set<Character> = Set("aeiouyAEIOUY")

    /// True when `ch` sits on a key that produces a Cyrillic LETTER in the
    /// Russian layout (";" → ж, "," → б, "." → ю, "[" → х, "'" → э…).
    /// Such characters are word content typed in the wrong layout and must
    /// NOT be treated as word boundaries — otherwise a Russian word typed in
    /// EN mode (";bpym" = "жизнь") is split in two and never corrected.
    static func producesRussianLetter(_ ch: Character) -> Bool {
        guard let ru = enToRu[ch] else { return false }
        return ru.isLetter
    }

    // MARK: - Public conversion

    /// Convert text typed under the assumption of `from` layout into what
    /// the user *meant* to type in `to` layout.
    static func convert(_ text: String, from: KeyboardLayout, to: KeyboardLayout) -> String {
        guard from != to else { return text }
        let table: [Character: Character] = (from == .english) ? enToRu : ruToEn
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            if let mapped = table[ch] {
                out.append(mapped)
            } else {
                // Digits / punctuation that map 1:1 pass through.
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Suspicion heuristics

    /// Verdict produced by the detector.
    enum Verdict {
        case looksCorrect
        case looksWrong(suggested: String, targetLayout: KeyboardLayout)
    }

    /// Decide whether the given word — typed while `current` layout was
    /// active — looks like it was meant for the other layout.
    static func analyze(word: String, current: KeyboardLayout) -> Verdict {
        // Trivial early exit: empty word.
        if word.isEmpty { return .looksCorrect }

        // Short words (1–2 letters): only the dictionary path can decide
        // safely. Letters like "a", "I", "я" must NOT be force-corrected.
        // We delegate to NSSpellChecker exclusively in this range.
        if word.count <= 2 {
            return analyzeShortWord(word, current: current)
        }

        switch current {
        case .english:
            // 1) Word contains Cyrillic? It's already in the right layout
            //    (rare but possible if user has mixed input). Leave it.
            if word.unicodeScalars.contains(where: { $0.value >= 0x0400 && $0.value <= 0x04FF }) {
                return .looksCorrect
            }

            // Count the keys that are LETTERS in the Russian layout, not just
            // Latin letters: in ",sk" (= "был") the ',' is the б key. Counting
            // only isLetter gave 2 and the word was skipped as too short.
            let letters = word.filter { $0.isLetter || producesRussianLetter($0) }

            // 2) Static heuristic: no English vowels, 3+ chars, translates
            //    into plausible Russian → wrong layout. The dictionary gate
            //    is mandatory: without it "http" (no vowels) translates to
            //    the plausible-looking gibberish "реез" and gets "corrected".
            if letters.count >= 3 {
                let vowelCount = letters.filter { englishVowels.contains($0) }.count
                if vowelCount == 0 || hasLongConsonantRun(word, vowels: englishVowels, threshold: 4) {
                    let translated = convert(word, from: .english, to: .russian)
                    if isPlausibleRussian(translated) && WordChecker.isRussian(translated) {
                        return .looksWrong(suggested: translated, targetLayout: .russian)
                    }
                }
            }

            // 3) Dictionary fallback: if the typed English is NOT a known
            //    English word but its Russian translation IS a known Russian
            //    word, that's a strong wrong-layout signal. This catches
            //    cases the static heuristic misses, e.g. a word with one
            //    accidental vowel-key in it.
            if letters.count >= 3 && !WordChecker.isEnglish(word) {
                let translated = convert(word, from: .english, to: .russian)
                if isPlausibleRussian(translated) && WordChecker.isRussian(translated) {
                    return .looksWrong(suggested: translated, targetLayout: .russian)
                }
            }
            return .looksCorrect

        case .russian:
            let letters = word.filter { $0.isLetter }
            let latinCount = word.unicodeScalars.filter {
                ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
            }.count
            let cyrillicCount = word.unicodeScalars.filter {
                $0.value >= 0x0400 && $0.value <= 0x04FF
            }.count

            // Mixed-script words (e.g. "цworld") are too ambiguous to fix
            // safely — leave them alone and let the user sort it out.
            if latinCount > 0 && cyrillicCount > 0 {
                return .looksCorrect
            }

            // 1) Pure Latin while in Russian mode → definitely wrong.
            if latinCount >= 2 && latinCount == letters.count {
                let translated = convert(word, from: .russian, to: .english)
                return .looksWrong(suggested: translated, targetLayout: .english)
            }

            // 2) Pure Cyrillic — two sub-rules in priority order:
            //    a) No Russian vowels at all → almost certainly wrong (legacy heuristic).
            //    b) Word is NOT a recognised Russian word, but its English
            //       translation IS a recognised English word → wrong layout.
            //       This is what fixes "руддщ"→"hello" / "ьщерук"→"mother".
            if letters.count >= 3 && cyrillicCount == letters.count {
                let translated = convert(word, from: .russian, to: .english)
                let vowelCount = letters.filter { russianVowels.contains($0) }.count

                if vowelCount == 0, isPlausibleEnglish(translated),
                   WordChecker.isEnglish(translated) {
                    return .looksWrong(suggested: translated, targetLayout: .english)
                }

                if !WordChecker.isRussian(word),
                   isPlausibleEnglish(translated),
                   WordChecker.isEnglish(translated) {
                    return .looksWrong(suggested: translated, targetLayout: .english)
                }
            }
            return .looksCorrect
        }
    }

    // MARK: - Short-word analysis (1–2 letters)

    /// Genuinely-usable single letters in normal English prose. Anything
    /// outside this set, typed alone, is almost certainly a wrong-layout
    /// typo — the user meant a Russian preposition / pronoun.
    private static let englishSingleLetters: Set<String> = ["a", "A", "I", "i"]

    /// Russian single-letter prepositions / pronoun "я". These appear
    /// constantly in normal Russian text and must never be auto-corrected.
    private static let russianSingleLetters: Set<String> = [
        "я", "Я", "в", "В", "у", "У", "с", "С", "к", "К",
        "о", "О", "и", "И", "а", "А", "ж", "Ж"
    ]

    /// For 1- and 2-letter words the macro heuristics (consonant clusters,
    /// vowel ratios) can't decide reliably. We split by length:
    ///
    ///   * **length == 1** — explicit per-language allowlist. If the typed
    ///     letter is NOT a real single-letter word in the current language,
    ///     but its conversion to the other layout IS one of the other
    ///     language's allowed single letters, correct it. (Fixes `f`→`а`,
    ///     `d`→`в`, `z`→`я`.)
    ///
    ///   * **length == 2** — NSSpellChecker, same as longer words: if the
    ///     typed word is NOT a known word in the current language but the
    ///     conversion IS, correct it. (Fixes `pf`→`за`, `yt`→`не`.)
    private static func analyzeShortWord(_ word: String, current: KeyboardLayout) -> Verdict {
        // Mixed-script — leave alone.
        let hasCyr = word.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        let hasLat = word.unicodeScalars.contains { ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) }
        if hasCyr && hasLat { return .looksCorrect }

        let other: KeyboardLayout = (current == .english) ? .russian : .english
        let translated = convert(word, from: current, to: other)

        // NOTE: the single-char path must run even when the typed character
        // is not a letter — ";" typed in EN mode is the Russian word "ж".
        if word.count == 1 {
            // Belongs to current-language safe list? Don't touch.
            let currentSet  = (current == .english) ? englishSingleLetters : russianSingleLetters
            let otherSet    = (other == .english)   ? englishSingleLetters : russianSingleLetters
            if currentSet.contains(word) { return .looksCorrect }
            // Goes from "junk in current" to "real preposition in other"?
            if otherSet.contains(translated) {
                return .looksWrong(suggested: translated, targetLayout: other)
            }
            return .looksCorrect
        }

        let letters = word.filter { $0.isLetter }
        guard !letters.isEmpty else { return .looksCorrect }

        // length == 2 — use the spell checker for both directions.
        let currentLang = (current == .english) ? "en" : "ru"
        let otherLang   = (other   == .english) ? "en" : "ru"

        if WordChecker.isKnownWord(word, language: currentLang) {
            return .looksCorrect
        }

        // Defensive: make sure the translation actually produces same-script letters.
        let translatedLetters = translated.filter { $0.isLetter }
        guard !translatedLetters.isEmpty else { return .looksCorrect }
        let targetScriptOK: Bool
        switch other {
        case .english:
            targetScriptOK = translatedLetters.allSatisfy { ch in
                guard let s = ch.unicodeScalars.first else { return false }
                return (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
            }
        case .russian:
            targetScriptOK = translatedLetters.allSatisfy { ch in
                guard let s = ch.unicodeScalars.first else { return false }
                return s.value >= 0x0400 && s.value <= 0x04FF
            }
        }
        guard targetScriptOK else { return .looksCorrect }

        if WordChecker.isKnownWord(translated, language: otherLang) {
            return .looksWrong(suggested: translated, targetLayout: other)
        }
        return .looksCorrect
    }

    // MARK: - Plausibility filters

    private static func isPlausibleRussian(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        guard letters.count >= 2 else { return false }
        // Every letter must be Cyrillic for us to be confident.
        for s in letters.unicodeScalars {
            if !(s.value >= 0x0400 && s.value <= 0x04FF) { return false }
        }
        // At least one vowel — protects against random key mashing.
        return letters.contains { russianVowels.contains($0) }
    }

    private static func isPlausibleEnglish(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        guard letters.count >= 2 else { return false }
        for s in letters.unicodeScalars {
            let isAscii = (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
            if !isAscii { return false }
        }
        return letters.contains { englishVowels.contains($0) }
    }

    private static func hasLongConsonantRun(_ word: String,
                                            vowels: Set<Character>,
                                            threshold: Int) -> Bool {
        var run = 0
        for ch in word where ch.isLetter {
            if vowels.contains(ch) { run = 0 } else { run += 1 }
            if run >= threshold { return true }
        }
        return false
    }
}
