//
//  LayoutManager.swift
//  AutoSwitcher
//
//  Phase 4: Wraps Carbon's TISInputSource APIs. We deliberately keep the
//  Carbon imports isolated here so the rest of the codebase stays in Swift /
//  AppKit land.
//
//  Note on SDK quirks: in current macOS SDKs the Carbon kTIS* string
//  constants are imported as `CFString?` (regular Optionals), not as
//  implicitly-unwrapped IUOs. We therefore unwrap them with `guard let`
//  before each use so the code compiles cleanly across SDK versions.
//
//  Threading: every method here touches TIS and is main-thread only
//  (switchTo marshals itself onto main when called from elsewhere).
//

import Foundation
import Carbon
import AppKit

/// A lightweight identifier for the two layouts we care about. Extending to
/// more layouts in the future is just a matter of adding cases and source IDs.
enum KeyboardLayout: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    /// Canonical TIS source IDs shipped on every macOS install, in order of
    /// preference when switching. Users can also have third-party layouts;
    /// `LayoutManager.classify` accepts those too.
    var canonicalSourceIDs: [String] {
        switch self {
        case .english:
            return ["com.apple.keylayout.US",
                    "com.apple.keylayout.ABC",
                    "com.apple.keylayout.British"]
        case .russian:
            return ["com.apple.keylayout.Russian",
                    "com.apple.keylayout.RussianWin",
                    "com.apple.keylayout.Russian-Phonetic"]
        }
    }
}

final class LayoutManager {

    /// Last source the user actually had selected for each language.
    /// Switching prefers it, so someone with both "Russian" and
    /// "Russian – PC" enabled is returned to the variant they really use.
    private var lastUsedSourceID: [KeyboardLayout: String] = [:]

    /// Remembered so an unsupported layout is logged once, not on every
    /// keystroke / every reconcile tick.
    private var lastUnclassifiedID: String?

    /// "enID|ruID" the current LayoutDetector key map was built from.
    private var keyMapSourcePair: String?

    // MARK: - Classification

    /// Map a TIS source ID to EN / RU, or nil for anything else.
    static func classify(sourceID: String) -> KeyboardLayout? {
        for layout in KeyboardLayout.allCases where layout.canonicalSourceIDs.contains(sourceID) {
            return layout
        }
        // Broaden the search: third-party layouts often embed a language code
        // or language name in the bundle id (e.g. "Russian-PC", "US-QWERTY").
        let lower = sourceID.lowercased()
        if lower.contains("russian") || lower.contains(".ru") || lower.contains("cyrillic") {
            return .russian
        }
        if lower.contains(".us") || lower.contains("english") || lower.contains(".abc")
            || lower.contains("british") || lower.contains("qwerty") || lower.contains("dvorak")
            || lower.contains("colemak") {
            return .english
        }
        return nil
    }

    /// Returns the layout currently active in the system, or nil if it is
    /// something other than English/Russian (we leave foreign layouts alone).
    func current() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let sourceID = sourceID(of: source) else {
            return nil
        }
        guard let layout = Self.classify(sourceID: sourceID) else {
            if lastUnclassifiedID != sourceID {
                lastUnclassifiedID = sourceID
                Diag.log("layout '\(sourceID)' is not classified as EN/RU — skipping")
            }
            return nil
        }
        lastUnclassifiedID = nil
        lastUsedSourceID[layout] = sourceID
        return layout
    }

    // MARK: - Switching

    /// Switches to the requested layout. Returns true on success.
    /// Safe to call from any thread: TIS APIs are documented as
    /// main-thread-only, so calls from the correction queue are marshalled
    /// onto the main queue synchronously (the caller needs the result and
    /// waits ~a millisecond at most).
    @discardableResult
    func switchTo(_ layout: KeyboardLayout) -> Bool {
        if Thread.isMainThread {
            return switchOnMainThread(layout)
        }
        var result = false
        DispatchQueue.main.sync {
            result = self.switchOnMainThread(layout)
        }
        return result
    }

    private func switchOnMainThread(_ layout: KeyboardLayout) -> Bool {
        guard let target = enabledSource(matching: layout) else { return false }
        let status = TISSelectInputSource(target)
        return status == noErr
    }

    // MARK: - Key translation (physical key → character in a layout)

    /// Physical keys that produce text. Used to build the EN↔RU character
    /// table and to decide how to replay keys typed during a correction.
    static let textKeyCodes: [CGKeyCode] = [
        kVK_ANSI_Grave, kVK_ISO_Section,
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0,
        kVK_ANSI_Minus, kVK_ANSI_Equal,
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T, kVK_ANSI_Y,
        kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O, kVK_ANSI_P,
        kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash,
        kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
        kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_Semicolon, kVK_ANSI_Quote,
        kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_N,
        kVK_ANSI_M, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash,
        kVK_Space
    ].map { CGKeyCode($0) }

    private static let textKeySet = Set(textKeyCodes)

    static func isTextKey(_ keyCode: CGKeyCode) -> Bool {
        textKeySet.contains(keyCode)
    }

    /// The character `keyCode` produces in the user's enabled `layout`
    /// (honouring Shift / Caps Lock), computed from the layout's own data —
    /// independent of which layout is selected right now.
    func character(forKeyCode keyCode: CGKeyCode, shift: Bool, capsLock: Bool,
                   in layout: KeyboardLayout) -> String? {
        guard let source = enabledSource(matching: layout) else { return nil }
        return translate(keyCode, shift: shift, capsLock: capsLock, source: source)
    }

    /// Rebuild LayoutDetector's EN↔RU character table from the layouts the
    /// user actually has enabled. Apple "Russian", "Russian – PC" and
    /// "Phonetic" disagree on punctuation and on where ё lives (and ABC vs
    /// British vs Dvorak disagree on the English side), so a hard-coded
    /// table is wrong for somebody. Cheap no-op while the chosen pair of
    /// sources is unchanged.
    func refreshKeyMapIfNeeded() {
        guard let en = enabledSource(matching: .english),
              let ru = enabledSource(matching: .russian),
              let enID = sourceID(of: en),
              let ruID = sourceID(of: ru) else { return }
        let pair = enID + "|" + ruID
        guard pair != keyMapSourcePair else { return }

        var pairs: [(Character, Character)] = []
        var seen = Set<Character>()
        for code in Self.textKeyCodes where code != CGKeyCode(kVK_Space) {
            for shift in [false, true] {
                guard let e = translate(code, shift: shift, capsLock: false, source: en),
                      let r = translate(code, shift: shift, capsLock: false, source: ru),
                      e.count == 1, r.count == 1,
                      let ec = e.first, let rc = r.first,
                      ec != rc, !seen.contains(ec) else { continue }
                seen.insert(ec)
                pairs.append((ec, rc))
            }
        }
        // A real EN/RU pair differs on 33+ letters alone. Anything less
        // means translation failed — keep whatever table we had.
        guard pairs.count >= 33 else {
            Diag.log("key map from \(pair) looks incomplete (\(pairs.count) keys) — keeping previous")
            return
        }
        keyMapSourcePair = pair
        LayoutDetector.installKeyMap(pairs)
        Diag.log("key map built from \(enID) + \(ruID) (\(pairs.count) keys)")
    }

    // MARK: - Private helpers

    private func sourceID(of source: TISInputSource) -> String? {
        guard let idKey = kTISPropertyInputSourceID,
              let raw = TISGetInputSourceProperty(source, idKey) else {
            return nil
        }
        let cf = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return cf as String
    }

    /// Enabled keyboard layouts (not input methods / emoji palettes).
    private func enabledKeyboardLayouts() -> [(id: String, source: TISInputSource)] {
        guard let typeKey = kTISPropertyInputSourceType,
              let layoutType = kTISTypeKeyboardLayout else {
            return []
        }
        // Build the filter dict with a plain Swift literal — Swift will bridge
        // [CFString: CFString] → CFDictionary through NSDictionary.
        let filter: CFDictionary = [typeKey: layoutType] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
                as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard let id = sourceID(of: source), isEnabled(source) else { return nil }
            return (id, source)
        }
    }

    private func isEnabled(_ source: TISInputSource) -> Bool {
        guard let enabledKey = kTISPropertyInputSourceIsEnabled,
              let raw = TISGetInputSourceProperty(source, enabledKey) else {
            // If we couldn't read the enabled flag, fall back to "selectable".
            return true
        }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    /// The enabled source to use for `layout`: the variant the user last
    /// had selected, else the canonical one, else any classified match.
    /// (The old substring test `id.contains("en")` also matched e.g.
    /// "French", so a switch to English could land on the wrong layout.)
    private func enabledSource(matching layout: KeyboardLayout) -> TISInputSource? {
        let candidates = enabledKeyboardLayouts().filter { Self.classify(sourceID: $0.id) == layout }
        if let preferred = lastUsedSourceID[layout],
           let hit = candidates.first(where: { $0.id == preferred }) {
            return hit.source
        }
        for canonical in layout.canonicalSourceIDs {
            if let hit = candidates.first(where: { $0.id == canonical }) {
                return hit.source
            }
        }
        return candidates.first?.source
    }

    private func translate(_ keyCode: CGKeyCode, shift: Bool, capsLock: Bool,
                           source: TISInputSource) -> String? {
        guard let dataKey = kTISPropertyUnicodeKeyLayoutData,
              let raw = TISGetInputSourceProperty(source, dataKey) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var modifiers: UInt32 = 0
        if shift { modifiers |= UInt32((shiftKey >> 8) & 0xFF) }
        if capsLock { modifiers |= UInt32((alphaLock >> 8) & 0xFF) }

        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(keyboardLayout,
                                    UInt16(keyCode),
                                    UInt16(kUCKeyActionDown),
                                    modifiers,
                                    UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &deadKeyState,
                                    chars.count,
                                    &length,
                                    &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
