import AppKit
import SwiftUI
import Carbon
import VerbCore

/// Listens for Verb's keys anywhere on the Mac. A key with modifiers ("⇧ ⌘ C", "F5") is a
/// system hotkey, which works even without Accessibility. Modifiers held on their own ("fn",
/// "⌃ ⌥"), Space and Escape go through the keyboard event tap, which needs it.
@MainActor final class Hotkeys {
    /// A binding for dictation, a voice edit or a question went down, or came up.
    var onDown: ((CaptureMode) -> Void)?
    var onUp: (() -> Void)?
    /// A modifiers-only binding went down and its short wait began; `onAbandon` when it turned
    /// out to be another shortcut. Verb opens the microphone in between.
    var onPending: ((CaptureMode) -> Void)?
    var onAbandon: (() -> Void)?
    /// Another key went down while a modifiers-only binding was held: perhaps a shortcut after all.
    var onOtherKey: (() -> Void)?
    /// Space while the dictation keys are held: hands-free from here on.
    var onHandsFree: (() -> Void)?
    var onStopHandsFree: (() -> Void)?
    var isHandsFreeActive: (() -> Bool)?
    var onCancel: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onNotepad: (() -> Void)?
    /// The hands-free key: starts a dictation, or finishes the one under way.
    var onToggle: (() -> Void)?
    /// The last characters typed in the app in front, for fitting a dictation to apps that don't show their text.
    let typing = TypingContext()
    var onTransform: ((Int) -> Void)?
    var isRecording: (() -> Bool)?
    /// Keys another app already holds, found when Settings stops listening.
    var onClash: ((String) -> Void)?
    /// Modifiers held on their own for a while and let go with no key, and for how long, in seconds.
    var onLoneModifiers: ((KeyModifiers, Double) -> Void)?
    /// A long text typed by hand in one app in the last minute, by its number of characters.
    var onTypedLong: ((Int) -> Void)?
    /// The answer card takes Return and Escape, as the first keys after it appears.
    var isAnswerArmed: (() -> Bool)?
    var onAnswerKey: ((Int64) -> Void)?
    /// Any other key, or a click: the card no longer takes Return and Escape.
    var onAnyOtherKey: (() -> Void)?
    /// Modifiers held since the keys were last all up, when they went down, and whether a key came with them.
    private var lone: (peak: KeyModifiers, since: Date, spoiled: Bool)?
    private var lastLongTyping = Date.distantPast
    /// While Settings listens for new keys, Verb acts on none of them.
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            cancelPending(); held = nil; heldKey = nil
            if suspended { unregister() }
            else if configured { do { try configure(keys, transforms: transformKeys) } catch { onClash?(error.localizedDescription) } }
        }
    }

    private var keys = KeyBindings()
    /// Each transform's keys, by its place in the list.
    private var transformKeys: [KeyBinding?] = []
    /// Set once the app has asked for its keys; the snapshot renderer never does.
    private var configured = false
    private var spaceStop = HandsFreeStop()
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    /// Watches clicks without holding them.
    private var clickTap: CFMachPort?
    private var tapSource: CFRunLoopSource?, clickSource: CFRunLoopSource?
    /// The taps run on a thread of their own, so a busy Verb never holds up the keys of the whole Mac.
    private var tapThread: TapThread?
    private lazy var link = TapLink(self)
    /// Checks that held keys are still down, in case their release never arrived.
    private var watchdog: Task<Void, Never>?
    /// A modifiers-only binding that is down but has not started yet: it may still turn out to
    /// be the start of another shortcut, such as ⌃⌥← or fn + Delete.
    private var pending: (mode: CaptureMode, task: Task<Void, Never>)?
    /// The modifiers-only binding that is running.
    private var held: CaptureMode?
    /// The binding with a key that is down, between its press and its release.
    private var heldKey: CaptureMode?

    init() {
        var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let service = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { service.hotkey(id.id, pressed: pressed) }
            return noErr
        }, events.count, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func hotkey(_ id: UInt32, pressed: Bool) {
        guard !suspended else { return }
        switch id {
        case 1, 2, 7:
            let mode: CaptureMode = id == 1 ? .dictation : id == 2 ? .command : .ask
            if pressed { guard heldKey == nil else { return }; heldKey = mode; onDown?(mode); watch() }
            else if heldKey == mode { heldKey = nil; onUp?() }
        case 3: if pressed { onPaste?() }
        case 4: if pressed { onCopy?() }
        case 5: if pressed { onNotepad?() }
        case 6: if pressed { onToggle?() }
        case 100...: if pressed { onTransform?(Int(id - 100)) }
        default: break
        }
    }

    func configure(_ keys: KeyBindings, transforms: [KeyBinding?]) throws {
        self.keys = keys; transformKeys = transforms; configured = true
        if heldKey != nil { heldKey = nil; onUp?() }
        unregister()
        guard !suspended else { return }
        var taken: [String] = []
        func add(_ binding: KeyBinding?, id: UInt32) {
            guard let binding, let code = binding.keyCode else { return }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(code, Self.carbon(binding.modifiers), EventHotKeyID(signature: 0x56455242, id: id), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { refs.append(reference) } else { taken.append(binding.label) }
        }
        add(keys.dictation, id: 1); add(keys.voiceEdit, id: 2); add(keys.ask, id: 7); add(keys.pasteLast, id: 3); add(keys.copyLast, id: 4); add(keys.notepad, id: 5); add(keys.handsFree, id: 6)
        for (index, binding) in transforms.enumerated() { add(binding, id: UInt32(100 + index)) }
        installTap()
        // The others still work; the first one taken is named.
        if let first = taken.first { throw VerbError("\(first) is already used by another app. Choose another shortcut in Settings.") }
    }

    private func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
    }

    /// The app keeping every key to itself with secure input, as a password field or Terminal's
    /// Secure Keyboard Entry does: Verb's keys can't reach Verb meanwhile. Empty when the app
    /// can't be named; nil when no app holds it, or Verb's own field does.
    static func secureInputApp() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let pid = ((CGSessionCopyCurrentDictionary() as? [String: Any])?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value ?? 0
        guard pid != getpid() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
    }

    /// Whether macOS uses these keys for one of its own shortcuts, as set in Keyboard Shortcuts.
    static func systemUses(_ binding: KeyBinding) -> Bool {
        guard let code = binding.keyCode else { return false }
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask: UInt32 = 0x1B00, wanted = carbon(binding.modifiers) & mask
        return entries.contains { entry in
            (entry["kHISymbolicHotKeyEnabled"] as? Bool) == true && (entry["kHISymbolicHotKeyCode"] as? Int) == Int(code)
                && (entry["kHISymbolicHotKeyModifiers"] as? Int).map { UInt32($0) & mask } == wanted
        }
    }

    static func carbon(_ modifiers: KeyModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    func installTap() {
        // A tap that stopped being valid, as after Accessibility was switched off and on, is made again.
        if let tap, !CFMachPortIsValid(tap) { removeTap() }
        guard tap == nil, AXIsProcessTrusted() else { return }
        let thread = tapThread ?? TapThread()
        tapThread = thread
        let loop = thread.loop
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<TapLink>.fromOpaque(context).takeUnretainedValue().holds(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(link).toOpaque())
        if let tap {
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(loop, tapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // Clicks are only watched, never held: after one, what was typed before the cursor is no longer known.
        if clickTap == nil {
            let clicks = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
            clickTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(clicks), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                Unmanaged<TapLink>.fromOpaque(context).takeUnretainedValue().clicked(type)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(link).toOpaque())
            if let clickTap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, clickTap, 0) {
                clickSource = source
                CFRunLoopAddSource(loop, source, .commonModes)
                CGEvent.tapEnable(tap: clickTap, enable: true)
            }
        }
        link.use(tap: tap, clickTap: clickTap)
        CFRunLoopWakeUp(loop)
    }
    /// Without Accessibility the taps can't work: they go, and come back once it is allowed.
    func removeTap() {
        guard tap != nil || clickTap != nil else { return }
        cancelPending(); if held != nil { held = nil; onUp?() }
        link.use(tap: nil, clickTap: nil)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: false); CFMachPortInvalidate(clickTap) }
        if let loop = tapThread?.loop {
            if let tapSource { CFRunLoopRemoveSource(loop, tapSource, .commonModes) }
            if let clickSource { CFRunLoopRemoveSource(loop, clickSource, .commonModes) }
        }
        tap = nil; clickTap = nil; tapSource = nil; clickSource = nil
    }
    /// After the tap was paused, keys let go meanwhile were never seen: the held binding ends if its keys are up.
    fileprivate func resync() {
        guard let mode = held else { return }
        if let keys = chord(mode), !Self.down(keys) { held = nil; onUp?() }
    }
    /// Whether these modifiers are held, by the keys themselves or by the flags the Mac keeps.
    /// The keys answer even when their release never reached Verb; the flags cover keyboards
    /// that report fn only there.
    static func down(_ modifiers: KeyModifiers, key: UInt32? = nil) -> Bool {
        let flags = KeyModifiers(CGEventSource.flagsState(.hidSystemState))
        let keys: [(KeyModifiers, [CGKeyCode])] = [(.control, [59, 62]), (.option, [58, 61]), (.shift, [56, 60]), (.command, [55, 54]), (.function, [63])]
        let held = keys.allSatisfy { modifier, codes in !modifiers.contains(modifier) || flags.contains(modifier) || codes.contains { CGEventSource.keyState(.hidSystemState, key: $0) } }
        return held && (key.map { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) } ?? true)
    }
    /// While a binding is down, its keys are checked four times a second: one whose release was
    /// lost, to a busy moment, secure input or a keyboard that dropped out, ends all the same.
    private func watch() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                if let mode = self.held, let keys = self.chord(mode), !Self.down(keys) { self.held = nil; self.onUp?() }
                if let mode = self.heldKey, let binding = self.binding(mode), let code = binding.keyCode, !Self.down(binding.modifiers, key: code) { self.heldKey = nil; self.onUp?() }
                if self.held == nil, self.heldKey == nil { self.watchdog = nil; return }
            }
        }
    }

    /// Whether the dictation keys are down, started or about to start.
    private var dictationDown: Bool { held == .dictation || pending?.mode == .dictation || heldKey == .dictation }

    /// True when the event is Verb's and must not reach the app in front.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard !suspended else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged { return modifiersChanged(KeyModifiers(event.flags), key: key) }
        let down = type == .keyDown, repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Escape cancels whatever Verb is doing.
        if key == 53, down, isRecording?() == true { cancelPending(); onCancel?(); return true }
        if down { lone?.spoiled = true }
        // The answer card: Return uses it and Escape closes it, if they are the next keys pressed.
        if down, !repeated, isAnswerArmed?() == true, !dictationDown {
            if [36, 76, 53].contains(key), event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty { onAnswerKey?(key); return true }
            onAnyOtherKey?()
        }
        // Space with the dictation keys held turns the dictation hands-free. Once it is, the
        // same Space does nothing: plain Space finishes.
        if key == 49, dictationDown {
            // Keys whose release was lost are not held: Space is Space again.
            if held != nil, let mode = held, let keys = chord(mode), !Self.down(keys) { held = nil; onUp?() }
            else {
                if down, !repeated, isHandsFreeActive?() != true { cancelPending(); onHandsFree?() }
                return true
            }
        }
        let modified = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty
        let decision = spaceStop.handle(keyCode: key, down: down, modified: modified, repeated: repeated, active: isHandsFreeActive?() == true)
        if decision.finish { onStopHandsFree?() }
        if decision.consume { return true }
        // Another key before a modifiers-only binding started: those modifiers were for a
        // shortcut, not for Verb. Once it has started, the dictation goes too if nothing was said yet.
        if down, pending != nil { cancelPending() } else if down, !repeated, held != nil { onOtherKey?() }
        if down {
            typing.typed(event)
            if Date().timeIntervalSince(lastLongTyping) > 30, typing.recentCount >= 120 { lastLongTyping = Date(); onTypedLong?(typing.recentCount) }
        }
        return false
    }
    /// A click anywhere.
    fileprivate func clicked() { typing.forget(); onAnyOtherKey?() }

    /// Follows the modifiers held on their own. A binding starts after a short wait, so a quick
    /// shortcut that begins with the same keys never starts it, and ends when its keys come up.
    private func modifiersChanged(_ now: KeyModifiers, key: Int64) -> Bool {
        // Modifiers held alone and let go, for the hint about the dictation keys.
        if now.isEmpty, let held = lone { lone = nil; if !held.spoiled { onLoneModifiers?(held.peak, Date().timeIntervalSince(held.since)) } }
        else if !now.isEmpty { if lone == nil { lone = (now, Date(), false) } else { lone?.peak.formUnion(now) } }
        if let mode = held, !now.isSuperset(of: chord(mode) ?? []) || chord(mode) == nil { held = nil; onUp?() }
        if let mode = pending?.mode, now != chord(mode) { cancelPending() }
        // ⌃⌥ held belongs to VoiceOver while it runs: every one of its commands starts that way.
        if held == nil, pending == nil, heldKey == nil, !(now.isSuperset(of: [.control, .option]) && NSWorkspace.shared.isVoiceOverEnabled) {
            for mode in [CaptureMode.dictation, .command, .ask] where chord(mode) == now { begin(mode); break }
        }
        // fn belongs to Verb while it is one of Verb's keys, rather than to the system's fn action.
        return key == 63 && [CaptureMode.dictation, .command, .ask].contains { chord($0)?.contains(.function) == true }
    }

    /// The keys held for dictation, a voice edit or a question.
    private func binding(_ mode: CaptureMode) -> KeyBinding? {
        switch mode { case .dictation: keys.dictation; case .command: keys.voiceEdit; case .ask: keys.ask }
    }
    /// The modifiers of a modifiers-only binding held to record; nil for a binding with a key, or none.
    private func chord(_ mode: CaptureMode) -> KeyModifiers? {
        let binding = binding(mode)
        return binding?.isModifierOnly == true ? binding?.modifiers : nil
    }

    private func begin(_ mode: CaptureMode) {
        // fn alone is quick to start. Several modifiers wait longer, as they often begin another shortcut.
        let wait: UInt64 = chord(mode) == [.function] ? 140_000_000 : 300_000_000
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self, self.pending?.mode == mode else { return }
            // A release lost on the way: the keys are already up, so nothing starts.
            guard let keys = self.chord(mode), Self.down(keys) else { self.cancelPending(); return }
            self.pending = nil; self.held = mode; self.lone?.spoiled = true; self.onDown?(mode); self.watch()
        }
        pending = (mode, task)
        onPending?(mode)
    }

    private func cancelPending() {
        guard let pending else { return }
        pending.task.cancel(); self.pending = nil
        onAbandon?()
    }
}

/// A thread that does nothing but run the keyboard taps.
private final class TapThread: Thread {
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    var loop: CFRunLoop { runLoop ?? CFRunLoopGetMain() }
    override init() {
        super.init()
        name = "Verb keys"; qualityOfService = .userInteractive
        start(); ready.wait()
    }
    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop going while no tap is on it.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }
}

/// Between the taps' thread and Hotkeys. Each key waits for Verb's answer for a moment at
/// most: when Verb is busy it passes untouched, as do the keys after it until Verb catches up,
/// and Verb still sees them all, in order.
private final class TapLink: @unchecked Sendable {
    private unowned let hotkeys: Hotkeys
    private let lock = NSLock()
    private var tap: CFMachPort?, clickTap: CFMachPort?
    /// Keys handed to Verb that it hasn't looked at yet.
    private var waiting = 0
    init(_ hotkeys: Hotkeys) { self.hotkeys = hotkeys }

    func use(tap: CFMachPort?, clickTap: CFMachPort?) { lock.lock(); self.tap = tap; self.clickTap = clickTap; lock.unlock() }

    /// True when the event is Verb's and must not reach the app in front.
    func holds(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = tap; lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            DispatchQueue.main.async { [self] in MainActor.assumeIsolated { hotkeys.resync() } }
            return false
        }
        // Verb's own ⌘V, ⌘C and arrows pass untouched.
        if event.getIntegerValueField(.eventSourceUserData) == TypingContext.marker { return false }
        guard let copy = event.copy() else { return false }
        let answer = Answer(), done = DispatchSemaphore(value: 0)
        lock.lock(); let behind = waiting > 0; waiting += 1; lock.unlock()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { answer.holds = hotkeys.handle(type: type, event: copy) }
            lock.lock(); waiting -= 1; lock.unlock()
            done.signal()
        }
        guard !behind, done.wait(timeout: .now() + .milliseconds(60)) == .success else { return false }
        return answer.holds
    }

    func clicked(_ type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let port = clickTap; lock.unlock()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return
        }
        DispatchQueue.main.async { [self] in MainActor.assumeIsolated { hotkeys.clicked() } }
    }

    private final class Answer: @unchecked Sendable { var holds = false }
}

extension KeyModifiers {
    init(_ flags: CGEventFlags) {
        var value: KeyModifiers = []
        if flags.contains(.maskControl) { value.insert(.control) }
        if flags.contains(.maskAlternate) { value.insert(.option) }
        if flags.contains(.maskShift) { value.insert(.shift) }
        if flags.contains(.maskCommand) { value.insert(.command) }
        if flags.contains(.maskSecondaryFn) { value.insert(.function) }
        self = value
    }
    init(_ flags: NSEvent.ModifierFlags) {
        var value: KeyModifiers = []
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.function) { value.insert(.function) }
        self = value
    }
}

/// Takes the keyboard while Settings listens for new keys: it reports the modifiers as they
/// are held, and the binding once the keys are pressed. Modifiers pressed and let go on their
/// own are a binding too ("fn", "⌃ ⌥"). Escape gives up, and Tab moves between the window's
/// buttons. Once keys are taken it stops listening, so Return uses them, until `listening` again.
struct KeyCaptureField: NSViewRepresentable {
    var listening = true
    let onHeld: (KeyModifiers) -> Void
    let onCapture: (KeyBinding) -> Void
    let onCancel: () -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onHeld = onHeld; view.onCapture = onCapture; view.onCancel = onCancel; view.listening = listening
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) {
        view.onHeld = onHeld; view.onCapture = onCapture; view.onCancel = onCancel
        if listening, !view.listening { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
        view.listening = listening
    }

    final class CaptureView: NSView {
        var listening = true
        var onHeld: (KeyModifiers) -> Void = { _ in }
        var onCapture: (KeyBinding) -> Void = { _ in }
        var onCancel: () -> Void = {}
        /// Every modifier held since the keys were last all up, and whether a key came with them.
        private var peak: KeyModifiers = []
        private var keyUsed = false
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.window?.makeFirstResponder(self) }
        }
        override func flagsChanged(with event: NSEvent) {
            guard listening else { super.flagsChanged(with: event); return }
            let now = KeyModifiers(event.modifierFlags)
            if now.isEmpty {
                if !peak.isEmpty, !keyUsed { onCapture(KeyBinding(modifiers: peak, label: peak.symbols)) }
                peak = []; keyUsed = false
            } else {
                peak.formUnion(now)
            }
            onHeld(now)
        }
        override func keyDown(with event: NSEvent) { if listening { take(event) } else { super.keyDown(with: event) } }
        // ⌘ combinations arrive as key equivalents, before any menu can claim them.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard listening, window?.firstResponder === self, event.type == .keyDown else { return false }
            take(event); return true
        }
        private func take(_ event: NSEvent) {
            if event.keyCode == 53 { onCancel(); return }
            // Tab and ⇧Tab move between the window's buttons, as everywhere else.
            if event.keyCode == 48, KeyModifiers(event.modifierFlags).subtracting([.shift, .function]).isEmpty {
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
                return
            }
            guard !event.isARepeat else { return }
            keyUsed = true
            // Arrows and F-keys report fn by themselves; fn is never part of a combination.
            let modifiers = KeyModifiers(event.modifierFlags).subtracting(.function)
            let name = Self.name(of: event)
            onCapture(KeyBinding(modifiers: modifiers, keyCode: UInt32(event.keyCode), label: modifiers.isEmpty ? name : modifiers.symbols + " " + name))
        }
        static func name(of event: NSEvent) -> String {
            let special: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
                                             122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
                                             105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
            if let name = special[event.keyCode] { return name }
            let character = event.charactersIgnoringModifiers?.uppercased() ?? ""
            return character.isEmpty ? "Key \(event.keyCode)" : character
        }
    }
}
