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

import Foundation
import Carbon
import AppKit

/// A lightweight identifier for the two layouts we care about. Extending to
/// more layouts in the future is just a matter of adding cases and source IDs.
enum KeyboardLayout: String, CaseIterable {
    case english = "en"
    case russian = "ru"

    /// Canonical TIS source IDs shipped on every macOS install.
    /// Users can also have third-party layouts (e.g. "Russian - PC"); the
    /// matching logic in `LayoutManager.current()` accepts either.
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

    /// Returns the layout currently active in the system, or nil if it is
    /// something other than English/Russian (we leave foreign layouts alone).
    func current() -> KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let sourceID = sourceID(of: source) else {
            return nil
        }
        for layout in KeyboardLayout.allCases {
            if layout.canonicalSourceIDs.contains(sourceID) {
                return layout
            }
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
        Diag.log("layout '\(sourceID)' is not classified as EN/RU — skipping")
        return nil
    }

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

    // MARK: - Private helpers

    private func sourceID(of source: TISInputSource) -> String? {
        guard let idKey = kTISPropertyInputSourceID,
              let raw = TISGetInputSourceProperty(source, idKey) else {
            return nil
        }
        let cf = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return cf as String
    }

    /// Walks enabled keyboard layouts and returns the first one matching the
    /// requested KeyboardLayout. We restrict to keyboard layouts (not e.g.
    /// emoji palettes) to avoid weird side effects.
    private func enabledSource(matching layout: KeyboardLayout) -> TISInputSource? {
        guard let typeKey = kTISPropertyInputSourceType,
              let layoutType = kTISTypeKeyboardLayout else {
            return nil
        }
        // Build the filter dict with a plain Swift literal — Swift will bridge
        // [CFString: CFString] → CFDictionary through NSDictionary.
        let filter: CFDictionary = [typeKey: layoutType] as CFDictionary

        guard let listRaw = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
                as? [TISInputSource] else {
            return nil
        }

        let enabledKey = kTISPropertyInputSourceIsEnabled

        for source in listRaw {
            guard let id = sourceID(of: source) else { continue }
            let matches = layout.canonicalSourceIDs.contains(id)
                       || id.lowercased().contains(layout.rawValue)
            guard matches else { continue }

            // Verify the source is actually enabled / selectable.
            if let enabledKey,
               let enabledRaw = TISGetInputSourceProperty(source, enabledKey) {
                let cfBool = Unmanaged<CFBoolean>.fromOpaque(enabledRaw).takeUnretainedValue()
                if CFBooleanGetValue(cfBool) {
                    return source
                }
            } else {
                // If we couldn't read the enabled flag, fall back to "selectable".
                return source
            }
        }
        return nil
    }
}
