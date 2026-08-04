//
//  SelectionConverter.swift
//  AutoSwitcher
//
//  ⌥⇧R: convert the currently selected text to the other layout.
//  Works through the pasteboard: synthesize ⌘C, read the selection,
//  convert by dominant script, paste the result with ⌘V, then restore
//  the user's previous clipboard string.
//
//  Limitation (documented): only the *string* flavor of the old clipboard
//  is restored. Non-text clipboard content (images, files) is lost when
//  the shortcut is used — same trade-off Caramba/Punto make.
//

import AppKit
import CoreGraphics
import Carbon.HIToolbox

enum SelectionConverter {

    /// Pure conversion logic (unit-tested): decide the dominant script of
    /// the text and convert it to the opposite layout. Returns nil when the
    /// text contains no EN/RU letters at all.
    static func convertDominant(_ text: String) -> (converted: String, target: KeyboardLayout)? {
        var latin = 0
        var cyrillic = 0
        for s in text.unicodeScalars {
            if (0x41...0x5A).contains(s.value) || (0x61...0x7A).contains(s.value) {
                latin += 1
            } else if (0x0400...0x04FF).contains(s.value) {
                cyrillic += 1
            }
        }
        if latin == 0 && cyrillic == 0 { return nil }
        let from: KeyboardLayout = latin >= cyrillic ? .english : .russian
        let to: KeyboardLayout = (from == .english) ? .russian : .english
        return (LayoutDetector.convert(text, from: from, to: to), to)
    }

    /// Full copy-convert-paste dance. Runs on a background queue; the
    /// synthesized ⌘C/⌘V events are tagged with the corrector sentinel so
    /// our own tap ignores them.
    static func convertSelection(layoutManager: LayoutManager) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pb = NSPasteboard.general
            let savedString = pb.string(forType: .string)
            let beforeCount = pb.changeCount

            // The user is physically still holding ⌥⇧ from the shortcut.
            // Posting ⌘C now would reach the app as ⌘⌥⇧C (hardware modifiers
            // merge with synthetic ones) and may trigger a different command.
            waitForModifiersReleased()

            postShortcut(virtualKey: CGKeyCode(kVK_ANSI_C))

            // Wait for the frontmost app to publish the selection (max 600 ms).
            var waited: TimeInterval = 0
            while pb.changeCount == beforeCount && waited < 0.6 {
                Thread.sleep(forTimeInterval: 0.05)
                waited += 0.05
            }

            guard pb.changeCount != beforeCount,
                  let selection = pb.string(forType: .string),
                  !selection.isEmpty,
                  let (converted, target) = convertDominant(selection) else {
                Diag.log("⌥⇧R: no convertible selection")
                restore(pb, savedString)
                return
            }

            pb.clearContents()
            pb.setString(converted, forType: .string)
            waitForModifiersReleased()
            postShortcut(virtualKey: CGKeyCode(kVK_ANSI_V))
            Thread.sleep(forTimeInterval: 0.25)

            // Follow the text: the user clearly wants to continue in the
            // target layout.
            layoutManager.switchTo(target)

            Thread.sleep(forTimeInterval: 0.15)
            restore(pb, savedString)
            Diag.log("⌥⇧R: selection converted to \(target.rawValue) (\(converted.count) chars)")
        }
    }

    /// Block (max 1 s) until the user releases all modifier keys so our
    /// synthetic ⌘C/⌘V are not polluted by physically held ⌥⇧.
    private static func waitForModifiersReleased(timeout: TimeInterval = 1.0) {
        var waited: TimeInterval = 0
        while waited < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.contains(.maskAlternate),
               !flags.contains(.maskShift),
               !flags.contains(.maskCommand),
               !flags.contains(.maskControl) {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
            waited += 0.02
        }
    }

    private static func restore(_ pb: NSPasteboard, _ saved: String?) {
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
    }

    private static func postShortcut(virtualKey: CGKeyCode) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true) {
            down.flags = .maskCommand
            down.setIntegerValueField(.eventSourceUserData, value: AutoCorrector.syntheticEventUserData)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) {
            up.flags = .maskCommand
            up.setIntegerValueField(.eventSourceUserData, value: AutoCorrector.syntheticEventUserData)
            up.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.03)
    }
}
