//
//  main.swift — end-to-end test for the INSTALLED, RUNNING AutoSwitcher.
//
//  Opens its own window with a plain NSTextView (all of macOS's own
//  autocorrect / substitutions disabled so they can't interfere), then
//  types into it with real key-down/up CGEvents — exactly what a keyboard
//  produces — and checks what AutoSwitcher turned the text into.
//
//  Safety: before EVERY keystroke the driver verifies that this app is
//  frontmost and its test window is key. If the user clicks elsewhere the
//  run aborts at once, so nothing is ever typed into another application.
//
//  Run via scripts/e2e.sh. It starts this binary as a CHILD process on
//  purpose: macOS then attributes the posted key events to the parent
//  (which holds Accessibility), whereas an app launched through `open`
//  would be its own "responsible process" without that permission.
//

import AppKit
import Carbon

// MARK: - Keyboard model (US/ABC keycaps)

/// Physical key + Shift for every character on the ABC layout, computed
/// from the layout itself so it matches the real keyboard.
let keyFor: [Character: (CGKeyCode, Bool)] = {
    var map: [Character: (CGKeyCode, Bool)] = [:]
    let filter = [kTISPropertyInputSourceID!: "com.apple.keylayout.ABC" as CFString] as CFDictionary
    guard let src = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first,
          let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return map }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
    let layout = UnsafeRawPointer(CFDataGetBytePtr(data)!).assumingMemoryBound(to: UCKeyboardLayout.self)
    for code in 0..<0x33 {   // all ANSI text keys live below kVK_Delete
        for shift in [false, true] {
            var dead: UInt32 = 0, len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let mods: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
            UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
            if len == 1, let ch = String(utf16CodeUnits: chars, count: 1).first, map[ch] == nil {
                map[ch] = (CGKeyCode(code), shift)
            }
        }
    }
    map[" "] = (CGKeyCode(kVK_Space), false)
    return map
}()

/// TIS is main-thread-only (macOS 27 asserts it), and the test steps run on
/// a background thread — so hop to main for every TIS call.
func onMain<T>(_ work: () -> T) -> T {
    Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
}

func selectLayout(_ id: String) {
    onMain {
        let filter = [kTISPropertyInputSourceID!: id as CFString] as CFDictionary
        if let src = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first {
            TISSelectInputSource(src)
        }
    }
}

func currentLayoutID() -> String {
    onMain {
        let s = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceID)).takeUnretainedValue() as String
    }
}

// MARK: - Test app

final class Harness: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    let outPath: String
    var report: [String] = []
    var passed = 0, failed = 0
    var aborted = false
    let source = CGEventSource(stateID: .hidSystemState)

    init(outPath: String) { self.outPath = outPath }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "AutoSwitcher E2E — please don't touch the keyboard"
        textView = NSTextView(frame: window.contentView!.bounds.insetBy(dx: 12, dy: 12))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 18)
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.enabledTextCheckingTypes = 0
        window.contentView!.addSubview(textView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: 1.0)
            runAll()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// ⌘C / ⌘V / ⌘A only work through the main menu's key equivalents.
    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        appItem.submenu = NSMenu()
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: Safety + primitives

    func ensureFocus() -> Bool {
        if aborted { return false }
        let ok = DispatchQueue.main.sync {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
                && window.isKeyWindow && window.firstResponder === textView
        }
        if !ok {
            aborted = true
            report.append("ABORTED: test window lost focus — stopped typing immediately")
        }
        return ok
    }

    /// A modifier key going down/up, as a real keyboard reports it: a
    /// separate flagsChanged event. Without these the system never learns
    /// the modifier is held (wrong characters) or released (stuck ⌥⇧).
    func modifier(_ code: Int, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)!
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
    }

    /// Press `code` like a human: modifiers down first, key down/up, then
    /// modifiers up in reverse order.
    func post(_ code: CGKeyCode, flags: CGEventFlags = []) {
        guard ensureFocus() else { return }
        let mods: [(Int, CGEventFlags)] = [
            (kVK_Option, .maskAlternate), (kVK_Shift, .maskShift)
        ].filter { flags.contains($0.1) }
        var held: CGEventFlags = []
        for (key, flag) in mods { held.insert(flag); modifier(key, flags: held) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
            e.flags = held
            e.post(tap: .cghidEventTap)
        }
        for (key, flag) in mods.reversed() { held.remove(flag); modifier(key, flags: held) }
    }

    /// Type the keycaps of `keys` (as printed on a US keyboard) at `interval`.
    func typeKeys(_ keys: String, interval: TimeInterval = 0.045) {
        for ch in keys {
            guard let (code, shift) = keyFor[ch] else {
                report.append("  ! no key for '\(ch)'"); continue
            }
            post(code, flags: shift ? .maskShift : [])
            Thread.sleep(forTimeInterval: interval)
        }
    }

    func optionTap() {
        guard ensureFocus() else { return }
        modifier(kVK_Option, flags: .maskAlternate)
        Thread.sleep(forTimeInterval: 0.08)
        modifier(kVK_Option, flags: [])
    }

    /// Wait until the field changes from `before` (async work such as ⌥⇧R).
    func waitForChange(from before: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && text == before { Thread.sleep(forTimeInterval: 0.1) }
    }

    var text: String { DispatchQueue.main.sync { textView.string } }

    /// Fresh field + fresh AutoSwitcher state (an arrow key resets its word
    /// buffer and "last word") + the starting layout for the case.
    func reset(layout: String) {
        DispatchQueue.main.sync { textView.string = "" }
        post(CGKeyCode(kVK_LeftArrow))
        selectLayout(layout)
        Thread.sleep(forTimeInterval: 0.5)
    }

    func check(_ name: String, _ expected: String, settle: TimeInterval = 0.9) {
        Thread.sleep(forTimeInterval: settle)
        guard !aborted else { return }
        let got = text
        if got == expected {
            passed += 1; report.append("  PASS  \(name)")
        } else {
            failed += 1; report.append("* FAIL  \(name)\n        expected: «\(expected)»\n        got:      «\(got)»")
        }
    }

    func checkLayout(_ name: String, _ expectedID: String) {
        guard !aborted else { return }
        let got = currentLayoutID()
        if got == expectedID { passed += 1; report.append("  PASS  \(name)") }
        else { failed += 1; report.append("* FAIL  \(name) — layout is \(got)") }
    }

    // MARK: Cases

    func snapshotClipboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    func runAll() {
        let original = currentLayoutID()
        let en = "com.apple.keylayout.ABC", ru = "com.apple.keylayout.Russian"
        let userClipboard = DispatchQueue.main.sync { snapshotClipboard() }
        defer {
            // Give any in-flight ⌥⇧R time to finish its own restore first.
            Thread.sleep(forTimeInterval: 1.5)
            DispatchQueue.main.sync {
                let pb = NSPasteboard.general
                pb.clearContents()
                if !userClipboard.isEmpty { pb.writeObjects(userClipboard) }
            }
            selectLayout(original)
            writeReport()
        }

        report.append("== basic corrections (start in ABC) ==")
        reset(layout: en); typeKeys("ghbdtn ");      check("ghbdtn␣ → привет␣", "привет ")
        checkLayout("layout switched to Russian after the correction", ru)
        reset(layout: en); typeKeys("ghbdtn? ");     check("ghbdtn?␣ → привет?␣ (Mac RU keeps ?)", "привет? ")
        reset(layout: en); typeKeys(";bpym ");       check(";bpym␣ → жизнь␣ (Ж key)", "жизнь ")
        reset(layout: en); typeKeys(",sk ");         check(",sk␣ → был␣ (Б key counts as a letter)", "был ")
        reset(layout: en); typeKeys("hello world "); check("real English stays: hello world␣", "hello world ")
        reset(layout: ru); typeKeys("hello ");       check("RU layout: руддщ␣ → hello␣", "hello ")

        report.append("== fast typing during a correction (type-ahead) ==")
        reset(layout: en); typeKeys("ghbdtn vbh ", interval: 0.008)
        check("ghbdtn vbh␣ at 8 ms/key → привет мир␣", "привет мир ", settle: 1.5)
        reset(layout: en); typeKeys("rfr ltkf? ", interval: 0.008)
        check("rfr ltkf?␣ at 8 ms/key → как дела?␣", "как дела? ", settle: 1.5)

        report.append("== ⌥ Option tap ==")
        reset(layout: en); typeKeys("ghbd"); optionTap(); Thread.sleep(forTimeInterval: 0.6); typeKeys("tn ")
        check("ghbd ⌥ tn␣ → привет␣ (convert word mid-typing)", "привет ")
        reset(layout: en); typeKeys("ghbctn "); optionTap()
        check("uncorrected ghbctn␣ ⌥ → присет␣ (convert last word)", "присет ")
        optionTap()
        check("second ⌥ toggles it back → ghbctn␣", "ghbctn ")
        reset(layout: en); typeKeys("cegth "); Thread.sleep(forTimeInterval: 0.7); optionTap()
        check("cegth␣ → супер␣, then ⌥ reverts WITH the space → cegth␣", "cegth ")
        checkLayout("layout back to ABC after the revert", en)

        report.append("== ⌥⇧R on a selection ==")
        reset(layout: en)
        let pb = NSPasteboard.general
        DispatchQueue.main.sync {
            pb.clearContents(); pb.setString("CLIPBOARD-SENTINEL", forType: .string)
            textView.string = "ghbdtn vbh"; textView.selectAll(nil)
        }
        post(CGKeyCode(kVK_ANSI_R), flags: [.maskAlternate, .maskShift])
        waitForChange(from: "ghbdtn vbh", timeout: 5)
        check("selected 'ghbdtn vbh' ⌥⇧R → привет мир", "привет мир", settle: 1.0)
        let clip = DispatchQueue.main.sync { pb.string(forType: .string) }
        if clip == "CLIPBOARD-SENTINEL" { passed += 1; report.append("  PASS  clipboard restored after ⌥⇧R") }
        else { failed += 1; report.append("* FAIL  clipboard after ⌥⇧R is «\(clip ?? "nil")»") }

        reset(layout: en)
        DispatchQueue.main.sync {
            textView.string = "abc"; textView.setSelectedRange(NSRange(location: 3, length: 0))
            pb.clearContents(); pb.setString("CLIPBOARD-SENTINEL", forType: .string)
        }
        post(CGKeyCode(kVK_ANSI_R), flags: [.maskAlternate, .maskShift])
        Thread.sleep(forTimeInterval: 2.0)
        let clip2 = DispatchQueue.main.sync { pb.string(forType: .string) }
        if clip2 == "CLIPBOARD-SENTINEL" && text == "abc" {
            passed += 1; report.append("  PASS  ⌥⇧R with no selection changes neither text nor clipboard")
        } else {
            failed += 1; report.append("* FAIL  ⌥⇧R with no selection: text «\(text)», clipboard «\(clip2 ?? "nil")»")
        }

        report.append("== Backspace right after a correction ==")
        reset(layout: en); typeKeys("cfvjktn "); Thread.sleep(forTimeInterval: 0.7)
        post(CGKeyCode(kVK_Delete))
        let afterBackspace = { () -> String in Thread.sleep(forTimeInterval: 0.9); return self.text }()
        report.append("  INFO  самолет␣ then ⌫ → «\(afterBackspace)» "
                      + "(«самолет» = plain delete of the space; «cfvjktn » = Smart Undo is on)")
    }

    func writeReport() {
        report.append("")
        report.append(aborted ? "RESULT: ABORTED (\(passed) passed, \(failed) failed before abort)"
                              : "RESULT: \(passed) passed, \(failed) failed")
        try? report.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }
}

let out = CommandLine.arguments.dropFirst().first ?? "/tmp/autoswitcher-e2e.txt"
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let harness = Harness(outPath: out)
app.delegate = harness
app.run()
