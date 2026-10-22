//
//  main.swift — offline test harness for AutoSwitcher's detection core.
//
//  There is no XCTest target (the project builds with plain Command Line
//  Tools), so scripts/test.sh compiles this file together with the real
//  app sources via swiftc and runs it. NSSpellChecker and the TIS keyboard
//  APIs work from a command-line process, so this exercises the actual
//  dictionaries and the keyboard layouts enabled on this Mac.
//
//  The "live key map" section expects Apple's ABC/US + "Russian" layouts;
//  on a machine with "Russian – PC" the punctuation expectations differ.
//

import Foundation
import AppKit
import Carbon

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS  \(name)") }
    else { failed += 1; print("* FAIL  \(name)") }
}

func expectWrong(_ word: String, _ layout: KeyboardLayout, _ expected: String, name: String? = nil) {
    let verdict = LayoutDetector.analyze(word: word, current: layout)
    switch verdict {
    case .looksWrong(let suggested, _):
        check(name ?? "\(word) (\(layout.rawValue)) → \(expected)", suggested == expected)
        if suggested != expected { print("        got: '\(suggested)'") }
    case .looksCorrect:
        check(name ?? "\(word) (\(layout.rawValue)) → \(expected)", false)
        print("        got: looksCorrect")
    }
}

func expectCorrect(_ word: String, _ layout: KeyboardLayout, name: String? = nil) {
    if case .looksWrong(let s, _) = LayoutDetector.analyze(word: word, current: layout) {
        check(name ?? "\(word) (\(layout.rawValue)) must stay untouched", false)
        print("        got: looksWrong('\(s)')")
    } else {
        check(name ?? "\(word) (\(layout.rawValue)) must stay untouched", true)
    }
}

print("== Fallback table (before the live map is built) ==")
check("fallback: ; → ж", LayoutDetector.convert(";", from: .english, to: .russian) == "ж")
check("fallback: ghbdtn → привет", LayoutDetector.convert("ghbdtn", from: .english, to: .russian) == "привет")
check("fallback: layout-specific '?' passes through", LayoutDetector.convert("?", from: .english, to: .russian) == "?")
check("fallback: layout-specific '/' passes through", LayoutDetector.convert("/", from: .english, to: .russian) == "/")

print("\n== LayoutManager.classify ==")
check("ABC → en", LayoutManager.classify(sourceID: "com.apple.keylayout.ABC") == .english)
check("US → en", LayoutManager.classify(sourceID: "com.apple.keylayout.US") == .english)
check("Russian → ru", LayoutManager.classify(sourceID: "com.apple.keylayout.Russian") == .russian)
check("RussianWin → ru", LayoutManager.classify(sourceID: "com.apple.keylayout.RussianWin") == .russian)
check("French → nil (old code could pick it for 'en')", LayoutManager.classify(sourceID: "com.apple.keylayout.French") == nil)
check("Ukrainian → nil", LayoutManager.classify(sourceID: "com.apple.keylayout.Ukrainian") == nil)
check("Belarusian → nil (old code could pick it for 'ru')", LayoutManager.classify(sourceID: "com.apple.keylayout.Belarusian") == nil)

print("\n== Live key map from the enabled layouts ==")
let lm = LayoutManager()
_ = lm.current()
lm.refreshKeyMapIfNeeded()
check("key V in RU → м", lm.character(forKeyCode: CGKeyCode(kVK_ANSI_V), shift: false, capsLock: false, in: .russian) == "м")
check("⇧V in RU → М", lm.character(forKeyCode: CGKeyCode(kVK_ANSI_V), shift: true, capsLock: false, in: .russian) == "М")
check("Caps V in RU → М", lm.character(forKeyCode: CGKeyCode(kVK_ANSI_V), shift: false, capsLock: true, in: .russian) == "М")
check("key ; in RU → ж", lm.character(forKeyCode: CGKeyCode(kVK_ANSI_Semicolon), shift: false, capsLock: false, in: .russian) == "ж")
check("key V in EN → v", lm.character(forKeyCode: CGKeyCode(kVK_ANSI_V), shift: false, capsLock: false, in: .english) == "v")
check("isTextKey(V)", LayoutManager.isTextKey(CGKeyCode(kVK_ANSI_V)))
check("isTextKey(Space)", LayoutManager.isTextKey(CGKeyCode(kVK_Space)))
check("!isTextKey(Delete)", !LayoutManager.isTextKey(CGKeyCode(kVK_Delete)))
check("!isTextKey(LeftArrow)", !LayoutManager.isTextKey(CGKeyCode(kVK_LeftArrow)))

print("\n== convert() mapping (Apple 'Russian' layout) ==")
check("ghbdtn → привет", LayoutDetector.convert("ghbdtn", from: .english, to: .russian) == "привет")
check(";bpym → жизнь", LayoutDetector.convert(";bpym", from: .english, to: .russian) == "жизнь")
check("ckj;yj → сложно", LayoutDetector.convert("ckj;yj", from: .english, to: .russian) == "сложно")
check("gj;fkeqcnf → пожалуйста", LayoutDetector.convert("gj;fkeqcnf", from: .english, to: .russian) == "пожалуйста")
check("Mac RU: ? stays ? (old table: → ,)", LayoutDetector.convert("?", from: .english, to: .russian) == "?")
check("Mac RU: / stays / (old table: → .)", LayoutDetector.convert("/", from: .english, to: .russian) == "/")
check("Mac RU: ^ (⇧6) → ,", LayoutDetector.convert("^", from: .english, to: .russian) == ",")
check("Mac RU: & (⇧7) → .", LayoutDetector.convert("&", from: .english, to: .russian) == ".")
check("Mac RU: \\ → ё", LayoutDetector.convert("\\", from: .english, to: .russian) == "ё")
check("Mac RU: ё → \\ (reverse)", LayoutDetector.convert("ё", from: .russian, to: .english) == "\\")
check("Mac RU: ` → ]", LayoutDetector.convert("`", from: .english, to: .russian) == "]")
check("руддщ → hello", LayoutDetector.convert("руддщ", from: .russian, to: .english) == "hello")
check("руддщю → hello.", LayoutDetector.convert("руддщю", from: .russian, to: .english) == "hello.")

print("\n== producesRussianLetter ==")
for ch in [";", ":", ",", "<", ".", ">", "[", "{", "]", "}", "'", "\"", "\\", "|"] {
    check("'\(ch)' buffers as letter key", LayoutDetector.producesRussianLetter(Character(ch)))
}
for ch in ["?", "/", " ", "!", "@", "(", ")", "=", "`", "~", "^", "&"] {
    check("'\(ch)' stays boundary", !LayoutDetector.producesRussianLetter(Character(ch)))
}

print("\n== EN mode: wrong-layout Russian ==")
expectWrong("ghbdtn", .english, "привет")
expectWrong(";bpym", .english, "жизнь", name: "Ж-bug: ;bpym → жизнь")
expectWrong("ckj;yj", .english, "сложно", name: "Ж-bug mid-word: ckj;yj → сложно")
expectWrong("vj;yj", .english, "можно")
expectWrong("cegth", .english, "супер")
expectWrong(";", .english, "ж", name: "standalone ';' → 'ж'")
expectWrong("yt", .english, "не")
expectWrong("gj", .english, "по")
expectCorrect("pf", .english, name: "pf is a known EN abbreviation — by design")

print("\n== EN mode: real English untouched ==")
for w in ["hello", "http", "https", "www", "myth", "test", "a", "I", "...", "hello,", "world;"] {
    expectCorrect(w, .english)
}

print("\n== RU mode: wrong-layout English ==")
expectWrong("руддщ", .russian, "hello")
expectWrong("ьщерук", .russian, "mother")
expectWrong("руддщю", .russian, "hello.", name: "hello. typed as руддщю")

print("\n== RU mode: real Russian untouched ==")
for w in ["привет", "жизнь", "уже", "привет,", "можно", "я", "ж", "мск", "ёлка"] {
    expectCorrect(w, .russian)
}

print("\n== WordChecker edge trimming ==")
check("isRussian(жизнь)", WordChecker.isRussian("жизнь"))
check("isRussian(привет,)", WordChecker.isRussian("привет,"))
check("isEnglish(hello;)", WordChecker.isEnglish("hello;"))
check("!isRussian(реез)", !WordChecker.isRussian("реез"))
check("!isEnglish(;bpym)", !WordChecker.isEnglish(";bpym"))

print("\n== SelectionConverter.convertDominant ==")
if let r = SelectionConverter.convertDominant("ghbdtn vbh") {
    check("'ghbdtn vbh' → 'привет мир' (ru)", r.converted == "привет мир" && r.target == .russian)
} else { check("'ghbdtn vbh' → 'привет мир' (ru)", false) }
if let r = SelectionConverter.convertDominant("руддщ цщкдв") {
    check("'руддщ цщкдв' → 'hello world' (en)", r.converted == "hello world" && r.target == .english)
} else { check("'руддщ цщкдв' → 'hello world' (en)", false) }
if let r = SelectionConverter.convertDominant(";bpym ghtrhfcyf") {
    check("Ж-keys selection → 'жизнь прекрасна'", r.converted == "жизнь прекрасна" && r.target == .russian)
} else { check("Ж-keys selection → 'жизнь прекрасна'", false) }
check("'12345' → nil", SelectionConverter.convertDominant("12345") == nil)
// Blind-typed "привет, как дела?" on Apple "Russian": comma is ⇧6, '?' is '?'.
if let r = SelectionConverter.convertDominant("ghbdtn^ rfr ltkf?") {
    check("sentence punctuation converts (Mac RU)", r.converted == "привет, как дела?" && r.target == .russian)
    if r.converted != "привет, как дела?" { print("        got: '\(r.converted)'") }
} else { check("sentence punctuation converts (Mac RU)", false) }

print("\n== UpdateChecker.isNewer ==")
check("1.4.1 > 1.4.0", UpdateChecker.isNewer("1.4.1", than: "1.4.0"))
check("1.10.0 > 1.9.1", UpdateChecker.isNewer("1.10.0", than: "1.9.1"))
check("2.0 > 1.9.9", UpdateChecker.isNewer("2.0", than: "1.9.9"))
check("!(1.4.0 > 1.4.0)", !UpdateChecker.isNewer("1.4.0", than: "1.4.0"))
check("!(1.3.9 > 1.4.0)", !UpdateChecker.isNewer("1.3.9", than: "1.4.0"))
check("1.4.0.1 > 1.4.0", UpdateChecker.isNewer("1.4.0.1", than: "1.4.0"))

print("\n=================================")
print("PASSED: \(passed)   FAILED: \(failed)")
exit(failed == 0 ? 0 : 1)
