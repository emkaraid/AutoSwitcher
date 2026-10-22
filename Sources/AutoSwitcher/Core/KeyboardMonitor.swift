//
//  KeyboardMonitor.swift
//  AutoSwitcher
//
//  Phase 3 (+ glue for 4/5/6/7/8): The CGEventTap that watches every key
//  press session-wide and feeds the detector / corrector pipeline.
//
//  Threading model:
//   - The tap is attached to the app's MAIN runloop (the most reliable
//     place on macOS 14+; private dispatch-queue runloops have shown
//     intermittent delivery problems where GCD reassigns worker threads).
//   - The tap callback is intentionally cheap: parse, update a buffered
//     string, optionally fire AutoCorrector.performCorrection — which then
//     does its actual posting on a global queue. So even though we run on
//     the main runloop, we never block on event delivery.
//
//  Safety:
//   - If the tap is killed by the system (timeout, error) we re-enable it.
//   - We never touch keystrokes when Secure Input is active.
//   - We never touch keystrokes for blacklisted apps.
//   - We never touch our own synthesized events (tagged via user data).
//   - Keys typed DURING a correction are held back and replayed after it,
//     so they can't interleave with the corrector's backspaces.
//

import Foundation
import AppKit
import CoreGraphics
import Carbon

final class KeyboardMonitor {

    // MARK: - Dependencies

    private let permissions: PermissionsManager
    private let autoCorrector: AutoCorrector
    private let layoutManager: LayoutManager
    private let smartUndo = SmartUndoManager()

    // MARK: - Tap state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?

    // MARK: - Typing state

    private let bufferLock = NSLock()
    private var typingBuffer: String = ""
    private let bufferMaxLen = 32

    /// One-shot flag: log the very first keystroke the tap ever delivers so
    /// we can prove in the logs that events are actually flowing.
    private var firstEventLogged = false

    /// While permissions are missing start() is retried on every settings
    /// change; log the failure once instead of on every attempt.
    private var tapFailureLogged = false

    // MARK: - Option-tap / revert-safety state (main-runloop confined)

    /// True while a "clean ⌥ tap" is still possible: Option went down alone
    /// and no key/click has happened since. Any other event cancels it.
    private var optionTapCandidate = false
    private var optionDownAt: Date?

    /// Set to false the moment a correction fires and back to true on the
    /// next real user event. Reverts (Backspace or ⌥) are only safe while
    /// the corrected text is still adjacent to the caret — i.e. while this
    /// flag is still false.
    private var userTypedSinceCorrection = true

    /// The last finished word (word + every boundary char typed after it)
    /// still sitting right before the caret — the target for manual ⌥
    /// conversion. Kept in sync with the screen: extra spaces/punctuation
    /// extend it, Backspace shrinks it, anything that moves the caret
    /// (clicks, arrows, Enter, shortcuts) clears it.
    private var lastCompleted: (word: String, boundary: String, at: Date)?

    /// How long after the fact a ⌥ tap may still revert / re-convert.
    private let optionRevertWindow: TimeInterval = 30

    /// True right after the user converted the word being typed with ⌥:
    /// that word is the user's explicit choice, so the detector must not
    /// "fix" it back at the next boundary. Reset together with the buffer.
    private var manualWordPending = false

    /// Physical keystrokes swallowed while a correction is being typed. The
    /// corrector takes them back via `drainQueuedKeys` and replays them in
    /// order right after its own events. Capped so a stuck state can never
    /// eat the keyboard — beyond the cap keys simply pass through.
    private var queuedKeys: [(code: CGKeyCode, flags: CGEventFlags)] = []
    private let queuedKeysLimit = 64

    init(permissions: PermissionsManager,
         autoCorrector: AutoCorrector,
         layoutManager: LayoutManager) {
        self.permissions = permissions
        self.autoCorrector = autoCorrector
        self.layoutManager = layoutManager
        autoCorrector.takeQueuedKeys = { [weak self] target in
            self?.drainQueuedKeys(for: target) ?? []
        }
    }

    deinit { stop() }

    // MARK: - Start / stop

    /// True while the tap is installed. Read by AppDelegate to make
    /// startEngineIfReady idempotent-and-quiet.
    var isRunning: Bool { eventTap != nil }

    func start() {
        guard eventTap == nil else { return }
        // NOTE: we deliberately do NOT gate on `permissions.isTrusted` here.
        // Polled TCC state can lag reality — especially right after rebuild
        // with ad-hoc signing, where cdhash changes and TCC daemon caches.
        // Just attempt the tap install. `CGEvent.tapCreate` returns nil iff
        // Accessibility is actually denied; if it succeeds but no events
        // ever arrive that's a 100% diagnostic for missing Input Monitoring.

        let mask: CGEventMask =
              (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: KeyboardMonitor.tapCallback,
            userInfo: selfPtr
        ) else {
            if !tapFailureLogged {
                tapFailureLogged = true
                Diag.log("FAILED to create CGEventTap — Accessibility may have been revoked. Toggle the app off and on again in System Settings → Privacy & Security → Accessibility.")
            }
            return
        }
        tapFailureLogged = false
        Diag.log("CGEventTap installed successfully")

        self.eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Diag.log("FAILED to create runloop source for tap")
            CGEvent.tapEnable(tap: tap, enable: false)
            self.eventTap = nil
            return
        }
        self.runLoopSource = source

        // Attach to the MAIN runloop. The earlier pattern of installing onto
        // a private dispatch queue's runloop (CFRunLoopGetCurrent() inside a
        // tapQueue.async block) is unreliable on macOS 14+ because GCD can
        // reassign the worker thread and the tap stops delivering. The main
        // runloop is always alive in an AppKit app and is the most boring,
        // predictable place to attach.
        let mainRL = CFRunLoopGetMain()
        self.tapRunLoop = mainRL
        CFRunLoopAddSource(mainRL, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Diag.log("tap attached to main runloop and enabled")
    }

    func stop() {
        guard eventTap != nil || runLoopSource != nil else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl = tapRunLoop, let src = runLoopSource {
            // Only detach the source — do NOT call CFRunLoopStop, the runloop
            // we're attached to is the app's main runloop and stopping it
            // would terminate the whole app.
            CFRunLoopRemoveSource(rl, src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        tapRunLoop = nil
        clearBuffer()
        lastCompleted = nil
        Diag.log("tap stopped")
    }

    // MARK: - Buffer helpers

    private func clearBuffer() {
        bufferLock.lock()
        typingBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        manualWordPending = false
    }

    private func append(_ s: String) {
        bufferLock.lock(); defer { bufferLock.unlock() }
        typingBuffer.append(s)
        if typingBuffer.count > bufferMaxLen {
            typingBuffer.removeFirst(typingBuffer.count - bufferMaxLen)
        }
    }

    private func dropLast() {
        bufferLock.lock(); defer { bufferLock.unlock() }
        if !typingBuffer.isEmpty { typingBuffer.removeLast() }
    }

    private func snapshotBuffer() -> String {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return typingBuffer
    }

    private func setBuffer(_ s: String) {
        bufferLock.lock(); defer { bufferLock.unlock() }
        typingBuffer = s
    }

    // MARK: - Screen-state bookkeeping (shared by live and replayed keys)

    /// A boundary char was typed and NOT used for a correction: close the
    /// word into `lastCompleted`, or — when there is no open word (second
    /// space, "!" then space…) — extend the boundary of the previous one so
    /// a ⌥ conversion deletes exactly what is on screen.
    private func noteBoundary(_ typed: String) {
        let word = snapshotBuffer()
        clearBuffer()
        if !word.isEmpty {
            lastCompleted = (word, typed, Date())
        } else if var completed = lastCompleted {
            completed.boundary += typed
            completed.at = Date()
            lastCompleted = completed
        }
    }

    /// A Backspace that is NOT a Smart Undo: mirror it on our state. With
    /// an empty buffer it eats into the last finished word's boundary; once
    /// the boundary is gone the word is "open" again and continues in the
    /// buffer ("hello␣" ⌫ "s" → buffer "hellos").
    private func noteBackspace() {
        if !snapshotBuffer().isEmpty {
            dropLast()
            if snapshotBuffer().isEmpty { manualWordPending = false }
            return
        }
        guard var completed = lastCompleted else { return }
        if !completed.boundary.isEmpty {
            completed.boundary.removeLast()
        }
        if completed.boundary.isEmpty {
            setBuffer(completed.word)
            lastCompleted = nil
        } else {
            lastCompleted = completed
        }
    }

    // MARK: - C trampoline

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    // MARK: - Main event handler

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Prove-of-life: log the first event that ever reaches us. After
        // that we stay quiet on the hot path.
        if !firstEventLogged && type == .keyDown {
            firstEventLogged = true
            Diag.log("first keyDown delivered to tap — engine is live")
        }

        // Re-enable if the system disabled us.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Diag.log("tap was disabled (\(type.rawValue)) — re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Ignore our own synthesized events.
        let userData = event.getIntegerValueField(.eventSourceUserData)
        if userData == AutoCorrector.syntheticEventUserData {
            return Unmanaged.passUnretained(event)
        }

        // The user's own keystrokes, re-posted after a correction: track
        // them (buffer / last word) but never act on them — they were typed
        // in one burst together with the word that was just corrected.
        if userData == AutoCorrector.replayEventUserData {
            if type == .keyDown { handleReplayed(event: event) }
            return Unmanaged.passUnretained(event)
        }

        // Pause completely while Secure Input is active.
        // Bool(...) makes the call resilient to the Carbon importer surfacing
        // this function as either Bool or DarwinBoolean across SDK versions.
        if Bool(IsSecureEventInputEnabled()) {
            clearBuffer()
            lastCompleted = nil
            optionTapCandidate = false
            return Unmanaged.passUnretained(event)
        }

        // Pause if the focused app is on the ignore list.
        if AppIgnoreList.isFrontmostAppIgnored() {
            clearBuffer()
            lastCompleted = nil
            optionTapCandidate = false
            return Unmanaged.passUnretained(event)
        }

        // While a correction is being posted, hold the user's keystrokes
        // back: letting them through would interleave them with our
        // synthetic backspaces ("привет" + a fast next letter → eaten or
        // misplaced characters). The corrector replays them right after.
        if autoCorrector.isCorrecting {
            optionTapCandidate = false
            if type == .keyDown, queuedKeys.count < queuedKeysLimit {
                queuedKeys.append((CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                                   event.flags))
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            clearBuffer()
            optionTapCandidate = false
            lastCompleted = nil
            userTypedSinceCorrection = true
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Modifier press/release alone (Shift, Cmd going down, Caps Lock).
            // Deliberately does NOT clear the buffer: Shift is part of normal
            // typing. Shortcut combos are filtered in handleKeyDown instead.
            handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)

        case .keyDown:
            return handleKeyDown(event: event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Type-ahead (keys typed during a correction)

    /// Called by the corrector on the main thread. Text keys are rendered
    /// straight from the target layout's key map — the system's own
    /// layout switch may still be propagating, so letting the OS translate
    /// the key code could still produce the OLD layout's character.
    private func drainQueuedKeys(for target: KeyboardLayout) -> [AutoCorrector.ReplayItem] {
        let keys = queuedKeys
        queuedKeys.removeAll()
        return keys.map { key in
            let flags = key.flags
            if !flags.contains(.maskCommand),
               !flags.contains(.maskControl),
               !flags.contains(.maskAlternate),
               LayoutManager.isTextKey(key.code),
               let text = layoutManager.character(forKeyCode: key.code,
                                                  shift: flags.contains(.maskShift),
                                                  capsLock: flags.contains(.maskAlphaShift),
                                                  in: target),
               !text.isEmpty {
                return .text(text)
            }
            return .key(key.code, flags)
        }
    }

    /// Bookkeeping for a replayed keystroke: same state updates as live
    /// typing, but no detection, no Smart Undo, no hotkeys.
    private func handleReplayed(event: CGEvent) {
        optionTapCandidate = false
        userTypedSinceCorrection = true

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            clearBuffer()
            lastCompleted = nil
            return
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_Delete {
            noteBackspace()
            return
        }
        if Self.caretMovingKeys.contains(keyCode) {
            clearBuffer()
            lastCompleted = nil
            return
        }
        guard let typed = unicodeString(from: event), !typed.isEmpty else { return }
        if isFunctionKeyText(typed) {
            clearBuffer()
            lastCompleted = nil
        } else if isWordBoundary(typed) {
            noteBoundary(typed)
        } else {
            append(typed)
        }
    }

    // MARK: - Option tap (Caramba-style revert / manual conversion)

    /// Track a "clean tap" of the Option key: ⌥ pressed alone and released
    /// with no key or click in between. Combos (⌥+letter for special chars,
    /// ⌥-drag…) cancel the candidate via the keyDown / mouse handlers.
    private func handleFlagsChanged(event: CGEvent) {
        let flags = event.flags
        let optionDown = flags.contains(.maskAlternate)
        let otherMods = flags.contains(.maskCommand)
            || flags.contains(.maskControl)
            || flags.contains(.maskShift)

        if optionDown && !otherMods {
            optionTapCandidate = true
            optionDownAt = Date()
        } else if !optionDown {
            if optionTapCandidate,
               let downAt = optionDownAt,
               Date().timeIntervalSince(downAt) < 0.5 {
                optionTapCandidate = false
                optionDownAt = nil
                handleOptionTap()
            } else {
                optionTapCandidate = false
                optionDownAt = nil
            }
        } else {
            // Option together with other modifiers — not a tap.
            optionTapCandidate = false
        }
    }

    /// Priority order:
    ///  1. Revert a fresh auto-correction (only while nothing was typed
    ///     after it — otherwise the backspaces would chew unrelated text).
    ///  2. Convert the word currently being typed (buffer non-empty).
    ///  3. Re-convert the last finished word; repeated taps toggle it
    ///     back and forth.
    private func handleOptionTap() {
        guard UserDefaults.standard.bool(forKey: AppSettings.Keys.optionTapEnabled) else { return }

        // Only AUTO corrections are reverted here. A manual ⌥ conversion is
        // toggled back by the buffer / lastCompleted paths below (converting
        // again), which keeps the typing buffer in sync and stays out of the
        // "add to Dictionary" feedback flow.
        if let last = autoCorrector.lastCorrection,
           !last.isManual,
           !userTypedSinceCorrection,
           Date().timeIntervalSince(last.timestamp) <= optionRevertWindow {
            Diag.log("⌥ tap: reverting last auto-correction")
            revert(last)
            return
        }

        let word = snapshotBuffer()
        if !word.isEmpty {
            Diag.log("⌥ tap: converting current word (\(word.count) chars)")
            if let converted = manualConvert(word: word, boundary: "") {
                // Keep typing seamless: the buffer now holds the converted
                // rendition, matching what is on screen — and the detector
                // must respect this explicit choice at the next boundary.
                setBuffer(converted)
                manualWordPending = true
                lastCompleted = nil
            }
            return
        }

        if let completed = lastCompleted,
           Date().timeIntervalSince(completed.at) <= optionRevertWindow {
            Diag.log("⌥ tap: converting last finished word (\(completed.word.count) chars)")
            if let converted = manualConvert(word: completed.word, boundary: completed.boundary) {
                // Store the converted rendition so another tap toggles back.
                let newBoundary = convertedBoundary(completed.boundary, of: completed.word)
                lastCompleted = (converted, newBoundary, Date())
            }
        }
    }

    /// Shared by the Backspace and ⌥ revert paths. Returns false when the
    /// corrector refused (the caller must then let its key through).
    @discardableResult
    private func revert(_ last: AutoCorrector.LastCorrection) -> Bool {
        let original = last.originalWrongText
        guard autoCorrector.revertLastCorrection() else { return false }
        // Remember the WRONG rendition — that is what is now on screen and
        // what the detector must leave alone for a while.
        smartUndo.remember(word: original)
        Diag.logSensitive("reverted to '\(original + last.originalTrailing)'")
        afterRevert(original: original)
        clearBuffer()
        // The restored text sits right before the caret again, so another
        // ⌥ tap converts it back (as a manual conversion).
        lastCompleted = last.originalTrailing.isEmpty
            ? nil
            : (original, last.originalTrailing, Date())
        if last.originalTrailing.isEmpty { setBuffer(original) }
        return true
    }

    /// Delete `word + boundary` before the caret and retype it in the other
    /// layout. Returns the converted word on success, nil when the layout of
    /// the text could not be determined or the corrector was busy.
    @discardableResult
    private func manualConvert(word: String, boundary: String) -> String? {
        let layout: KeyboardLayout
        if let derived = layoutFromBufferScript(word) {
            layout = derived
        } else if let sys = layoutManager.current() {
            layout = sys
        } else {
            return nil
        }
        let target: KeyboardLayout = (layout == .english) ? .russian : .english
        let converted = LayoutDetector.convert(word, from: layout, to: target)
        let boundaryConverted = LayoutDetector.convert(boundary, from: layout, to: target)
        Diag.logSensitive("⌥ convert '\(word + boundary)' (\(layout.rawValue)) → '\(converted + boundaryConverted)' (\(target.rawValue))")
        let playSound = UserDefaults.standard.bool(forKey: AppSettings.Keys.playSoundOnSwitch)
        guard autoCorrector.performCorrection(
            originalWrong: word + boundary,
            corrected: converted + boundaryConverted,
            fromLayout: layout,
            toLayout: target,
            playSound: playSound,
            isManual: true
        ) else { return nil }
        userTypedSinceCorrection = false
        return converted
    }

    private func convertedBoundary(_ boundary: String, of word: String) -> String {
        guard let layout = layoutFromBufferScript(word) ?? layoutManager.current() else { return boundary }
        let target: KeyboardLayout = (layout == .english) ? .russian : .english
        return LayoutDetector.convert(boundary, from: layout, to: target)
    }

    /// Common post-revert feedback: count the revert, auto-add to Dictionary
    /// after the second revert of the same word (if auto-learn is enabled),
    /// otherwise show the "add to Dictionary?" toast.
    private func afterRevert(original: String) {
        let count = smartUndo.registerRevert(word: original)
        let autoLearn = UserDefaults.standard.bool(forKey: AppSettings.Keys.autoLearnEnabled)
        if autoLearn && count >= 2 {
            Whitelist.add(original)
            Diag.log("auto-learn: word added to Dictionary after \(count) reverts")
            UndoToastWindow.shared.showAutoAdded(word: original)
        } else {
            UndoToastWindow.shared.show(originalWord: original)
        }
    }

    // MARK: - Key handling

    /// Keys that move the caret / leave the field: the typing buffer and
    /// the last finished word are no longer adjacent to the caret.
    private static let caretMovingKeys: Set<Int> = [
        kVK_Escape, kVK_Tab, kVK_Return, kVK_ANSI_KeypadEnter, kVK_ForwardDelete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Help
    ]

    private func handleKeyDown(event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Any real key press cancels a pending ⌥ tap and marks that typing
        // happened after the last correction. `hadTyped` preserves the state
        // as it was BEFORE this key for the Backspace-revert safety check.
        optionTapCandidate = false
        let hadTyped = userTypedSinceCorrection
        userTypedSinceCorrection = true

        // ⌥⇧R — convert the currently selected text to the other layout.
        if Int(keyCode) == kVK_ANSI_R,
           event.flags.contains(.maskAlternate),
           event.flags.contains(.maskShift),
           !event.flags.contains(.maskCommand),
           !event.flags.contains(.maskControl),
           UserDefaults.standard.bool(forKey: AppSettings.Keys.convertSelectionEnabled) {
            clearBuffer()
            lastCompleted = nil
            SelectionConverter.convertSelection(layoutManager: layoutManager)
            return nil
        }

        // Keyboard shortcuts (⌘Z, ⌃A, ⌥-anything) are not text input. Without
        // this check the letter of the shortcut lands in the typing buffer and
        // can later cause a bogus correction of a word the user never typed.
        if event.flags.contains(.maskCommand)
            || event.flags.contains(.maskControl)
            || event.flags.contains(.maskAlternate) {
            clearBuffer()
            lastCompleted = nil
            return Unmanaged.passUnretained(event)
        }

        // Enter: optionally run the detector on the last word BEFORE the
        // newline reaches the app (off by default — in chats this corrects
        // the message that is being sent). The physical key is eaten on
        // correction and re-pressed — with its modifiers, so ⇧⏎ stays a
        // newline — by the corrector after retyping.
        if Int(keyCode) == kVK_Return || Int(keyCode) == kVK_ANSI_KeypadEnter {
            let word = snapshotBuffer()
            let skip = manualWordPending
            clearBuffer()
            lastCompleted = nil
            if UserDefaults.standard.bool(forKey: AppSettings.Keys.correctOnEnter),
               !word.isEmpty, !skip,
               evaluate(word: word, trailing: "", trailingKey: (keyCode, event.flags)) {
                Diag.log("correction on Enter — eating key")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Bail-out keys: reset the buffer and pass through. They all move
        // the caret, so the last finished word is no longer reachable.
        if Self.caretMovingKeys.contains(Int(keyCode)) {
            clearBuffer()
            lastCompleted = nil
            return Unmanaged.passUnretained(event)
        }

        // Smart Undo on Backspace. Only while nothing was typed since the
        // correction — otherwise the revert would delete unrelated text.
        if Int(keyCode) == kVK_Delete {
            let undoEnabled = UserDefaults.standard.bool(forKey: AppSettings.Keys.smartUndoEnabled)
            if undoEnabled, !hadTyped,
               smartUndo.shouldHandleBackspace(corrector: autoCorrector),
               let last = autoCorrector.lastCorrection,
               !last.isManual,
               revert(last) {
                Diag.log("Smart Undo fired")
                return nil
            }
            noteBackspace()
            return Unmanaged.passUnretained(event)
        }

        // Extract the typed unicode characters from the event.
        let typed = unicodeString(from: event)

        // F-keys, Fn+arrows & co. report private-use "characters"
        // (U+F700…). They are not text: treating them as a word boundary
        // would let a correction eat the key and type that glyph instead.
        if let typed, isFunctionKeyText(typed) {
            clearBuffer()
            lastCompleted = nil
            return Unmanaged.passUnretained(event)
        }

        // Word-boundary characters: end of word, run detection on the buffer.
        //
        // IMPORTANT: if we trigger an auto-correction we must EAT the boundary
        // character here (return nil) and hand it to the corrector so it gets
        // re-typed *after* the backspaces. Otherwise the boundary would reach
        // the focused app first, our backspaces would chew through it and
        // (N-1) characters of the wrong word, leaving the first letter as
        // residue (the "gпривет" / "rкакая" bug from real-world testing).
        if let typed, isWordBoundary(typed) {
            let word = snapshotBuffer()
            if !word.isEmpty && !manualWordPending {
                Diag.logSensitive("boundary '\(typed)' after word '\(word)'")
                if evaluate(word: word, trailing: typed) {
                    Diag.log("correction triggered — eating boundary")
                    clearBuffer()
                    lastCompleted = nil
                    return nil
                }
            }
            // No correction: remember the word for manual ⌥ conversion.
            noteBoundary(typed)
            return Unmanaged.passUnretained(event)
        }

        // Otherwise accumulate the keystroke into the buffer.
        if let typed, !typed.isEmpty {
            append(typed)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Detection trigger

    /// Returns true if an auto-correction was actually started.
    /// `trailing` is the word-boundary character that triggered evaluation;
    /// when correction fires it is appended (converted to the target
    /// layout) to the retyped corrected text so the focused document ends up
    /// with `corrected + boundary`, and the caller eats the boundary key.
    @discardableResult
    private func evaluate(word: String, trailing: String,
                          trailingKey: (code: CGKeyCode, flags: CGEventFlags)? = nil) -> Bool {
        // Phase 7 — whitelist check.
        let whitelist = UserDefaults.standard.stringArray(forKey: AppSettings.Keys.whitelistWords) ?? []
        if whitelist.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            return false
        }

        // Smart-Undo memory: don't immediately re-correct a freshly reverted word.
        if smartUndo.isRecentlyReverted(word) {
            return false
        }

        // Phase 8 — skip if word contains digits/specials and the option is on.
        let skipDigits = UserDefaults.standard.bool(forKey: AppSettings.Keys.ignoreWordsWithDigits)
        if skipDigits {
            if word.contains(where: { $0.isNumber }) { return false }
            // Special character heuristic: anything that is neither a letter
            // nor a hyphen / apostrophe (real word punctuation) → skip.
            // Characters that produce Cyrillic letters in RU (';' = ж,
            // ',' = б, …) are NOT specials — they are the wrong-layout
            // rendition of the word itself and must stay correctable.
            if word.contains(where: { ch in
                !ch.isLetter && ch != "-" && ch != "'"
                    && !LayoutDetector.producesRussianLetter(ch)
            }) { return false }
        }

        // Skip when Caps Lock is on (likely intentional shouting / passwords).
        if isCapsLockOn() {
            Diag.logSensitive("skip '\(word)' — CapsLock")
            return false
        }

        // Determine the layout that was actually in effect WHILE THE BUFFER
        // WAS BEING FILLED — not whatever the system reports right now. This
        // is critical: after an auto-correction we call TISSelectInputSource,
        // and the system flip can take longer to propagate than the user
        // takes to type the next keys. In the "rfr ltkf?" trace from
        // real-world testing the keys for ltkf landed in EN-still-active
        // mode (so unicodeString returned Latin l,t,k,f), but by the time
        // the trailing '?' arrived the system had finally moved to RU and
        // layoutManager.current() reported RU — leading to a bogus
        // "Latin-in-Russian" verdict and the wrong correction.
        //
        // The buffer content itself is unambiguous: if every letter is
        // Latin, the user was physically in EN when typing the word. If
        // every letter is Cyrillic, they were in RU. We trust that.
        let systemLayout = layoutManager.current()
        let layout: KeyboardLayout
        if let derived = layoutFromBufferScript(word) {
            if let sys = systemLayout, sys != derived {
                Diag.log("buffer script says \(derived.rawValue), system says \(sys.rawValue) — trusting buffer (async-switch race)")
            }
            layout = derived
        } else if let sys = systemLayout {
            layout = sys
        } else {
            Diag.logSensitive("skip '\(word)' — current layout not recognised (not EN/RU)")
            return false
        }

        let verdict = LayoutDetector.analyze(word: word, current: layout)
        switch verdict {
        case .looksCorrect:
            Diag.logSensitive("'\(word)' looks fine in \(layout.rawValue)")
            return false
        case .looksWrong(let suggested, let target):
            // The boundary key itself can mean different punctuation in the
            // target layout (on "Russian – PC" the '?' key types ','). The
            // live key map knows the user's real layouts.
            let boundary = LayoutDetector.convert(trailing, from: layout, to: target)
            Diag.log("CORRECT \(layout.rawValue)→\(target.rawValue), \(word.count) chars")
            Diag.logSensitive("CORRECT '\(word)' (\(layout.rawValue)) → '\(suggested)' (\(target.rawValue))")
            let playSound = UserDefaults.standard.bool(forKey: AppSettings.Keys.playSoundOnSwitch)
            guard autoCorrector.performCorrection(
                originalWrong: word,
                originalTrailing: trailing,
                corrected: suggested + boundary,
                fromLayout: layout,
                toLayout: target,
                playSound: playSound,
                trailingKey: trailingKey
            ) else { return false }
            userTypedSinceCorrection = false
            return true
        }
    }

    /// Look at the script of the letters in the typed buffer and return the
    /// keyboard layout the user must have been in to produce those glyphs.
    /// Returns nil for mixed scripts (let the caller fall back to the system).
    private func layoutFromBufferScript(_ word: String) -> KeyboardLayout? {
        var latin = 0
        var cyrillic = 0
        for scalar in word.unicodeScalars {
            let v = scalar.value
            if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) {
                latin += 1
            } else if v >= 0x0400 && v <= 0x04FF {
                cyrillic += 1
            }
        }
        if latin > 0 && cyrillic == 0 { return .english }
        if cyrillic > 0 && latin == 0 { return .russian }
        return nil
    }

    // MARK: - Helpers

    private func unicodeString(from event: CGEvent) -> String? {
        var length: Int = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        if length == 0 { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    /// AppKit's function-key range (NSUpArrowFunctionKey … ), plus the rest
    /// of the private-use area some keyboards report.
    private func isFunctionKeyText(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        return (0xF700...0xF8FF).contains(first.value)
    }

    private func isWordBoundary(_ s: String) -> Bool {
        if s.isEmpty { return false }
        // Treat whitespace, punctuation marks and most ASCII symbols as boundaries.
        for ch in s {
            if ch.isLetter { return false }
            // Digits are part of identifiers/words ("test123"), not boundaries.
            if ch.isNumber { return false }
            if ch == "-" || ch == "'" { return false }
            // Keys like ';' ',' '.' '[' produce Cyrillic LETTERS (ж б ю х) in
            // the Russian layout. They are word content, not boundaries —
            // otherwise "жизнь" typed in EN mode (";bpym") is split in two.
            if LayoutDetector.producesRussianLetter(ch) { return false }
        }
        return true
    }

    private func isCapsLockOn() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskAlphaShift)
    }
}
