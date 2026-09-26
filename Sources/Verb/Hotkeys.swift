import AppKit
import SwiftUI
import Carbon
import VerbCore

/// Listens for Verb's keys anywhere on the Mac. A key with modifiers ("⇧ ⌘ C", "F5") is a
/// system hotkey, which works even without Accessibility. Modifiers held on their own ("fn",
/// "⌃ ⌥"), Space and Escape go through the keyboard event tap, which needs it.
@MainActor final class Hotkeys {
    /// A binding for dictation or voice editing went down, or came up.
    var onDown: ((CaptureMode) -> Void)?
    var onUp: (() -> Void)?
    /// Space while the dictation keys are held: hands-free from here on.
    var onHandsFree: (() -> Void)?
    var onStopHandsFree: (() -> Void)?
    var isHandsFreeActive: (() -> Bool)?
    var onCancel: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCopy: (() -> Void)?
    var onNotepad: (() -> Void)?
    /// The last characters typed in the app in front, for fitting a dictation to apps that don't show their text.
    let typing = TypingContext()
    var onTransform: ((Int) -> Void)?
    var isRecording: (() -> Bool)?
    /// Keys another app already holds, found when Settings stops listening.
    var onClash: ((String) -> Void)?
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
        case 1, 2:
            let mode: CaptureMode = id == 1 ? .dictation : .command
            if pressed { guard heldKey == nil else { return }; heldKey = mode; onDown?(mode) }
            else if heldKey == mode { heldKey = nil; onUp?() }
        case 3: if pressed { onPaste?() }
        case 4: if pressed { onCopy?() }
        case 5: if pressed { onNotepad?() }
        case 100...: if pressed { onTransform?(Int(id - 100)) }
        default: break
        }
    }

    func configure(_ keys: KeyBindings, transforms: [KeyBinding?]) throws {
        self.keys = keys; transformKeys = transforms; configured = true
        unregister()
        guard !suspended else { return }
        var taken: [String] = []
        func add(_ binding: KeyBinding?, id: UInt32) {
            guard let binding, let code = binding.keyCode else { return }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(code, Self.carbon(binding.modifiers), EventHotKeyID(signature: 0x56455242, id: id), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { refs.append(reference) } else { taken.append(binding.label) }
        }
        add(keys.dictation, id: 1); add(keys.voiceEdit, id: 2); add(keys.pasteLast, id: 3); add(keys.copyLast, id: 4); add(keys.notepad, id: 5)
        for (index, binding) in transforms.enumerated() { add(binding, id: UInt32(100 + index)) }
        installTap()
        // The others still work; the first one taken is named.
        if let first = taken.first { throw VerbError("\(first) is already used by another app. Choose another shortcut in Settings.") }
    }

    private func unregister() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs = []
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
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { service.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event) }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        // Clicks are only watched, never held: after one, what was typed before the cursor is no longer known.
        guard clickTap == nil else { return }
        let clicks = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        clickTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(clicks), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown { MainActor.assumeIsolated { service.typing.forget() } }
            else if let tap = MainActor.assumeIsolated({ service.clickTap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let clickTap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, clickTap, 0) {
            clickSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: clickTap, enable: true)
        }
    }
    /// Without Accessibility the taps can't work: they go, and come back once it is allowed.
    func removeTap() {
        guard tap != nil || clickTap != nil else { return }
        cancelPending(); if held != nil { held = nil; onUp?() }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: false); CFMachPortInvalidate(clickTap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let clickSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), clickSource, .commonModes) }
        tap = nil; clickTap = nil; tapSource = nil; clickSource = nil
    }
    /// After the tap was paused, keys let go meanwhile were never seen: the held binding ends if its keys are up.
    private func resync() {
        guard let mode = held else { return }
        let now = KeyModifiers(CGEventSource.flagsState(.combinedSessionState))
        if let keys = chord(mode), !now.isSuperset(of: keys) { held = nil; onUp?() }
    }

    /// Whether the dictation keys are down, started or about to start.
    private var dictationDown: Bool { held == .dictation || pending?.mode == .dictation || heldKey == .dictation }

    /// True when the event is Verb's and must not reach the app in front.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; resync(); return false }
        // Verb's own ⌘V, ⌘C and arrows pass untouched.
        if event.getIntegerValueField(.eventSourceUserData) == TypingContext.marker { return false }
        guard !suspended else { return false }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .flagsChanged { return modifiersChanged(KeyModifiers(event.flags), key: key) }
        let down = type == .keyDown, repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Escape cancels whatever Verb is doing.
        if key == 53, down, isRecording?() == true { cancelPending(); onCancel?(); return true }
        // Space with the dictation keys held turns the dictation hands-free. Once it is, the
        // same Space does nothing: plain Space finishes.
        if key == 49, dictationDown {
            if down, !repeated, isHandsFreeActive?() != true { cancelPending(); onHandsFree?() }
            return true
        }
        let modified = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty
        let decision = spaceStop.handle(keyCode: key, down: down, modified: modified, repeated: repeated, active: isHandsFreeActive?() == true)
        if decision.finish { onStopHandsFree?() }
        if decision.consume { return true }
        // Another key before a modifiers-only binding started: those modifiers were for a
        // shortcut, not for Verb. Once it has started, other keys leave it alone.
        if down, pending != nil { cancelPending() }
        if down { typing.typed(event) }
        return false
    }

    /// Follows the modifiers held on their own. A binding starts after a short wait, so a quick
    /// shortcut that begins with the same keys never starts it, and ends when its keys come up.
    private func modifiersChanged(_ now: KeyModifiers, key: Int64) -> Bool {
        if let mode = held, !now.isSuperset(of: chord(mode) ?? []) || chord(mode) == nil { held = nil; onUp?() }
        if let mode = pending?.mode, now != chord(mode) { cancelPending() }
        if held == nil, pending == nil, heldKey == nil {
            for mode in [CaptureMode.dictation, .command] where chord(mode) == now { begin(mode); break }
        }
        // fn belongs to Verb while it is one of Verb's keys, rather than to the system's fn action.
        return key == 63 && [CaptureMode.dictation, .command].contains { chord($0)?.contains(.function) == true }
    }

    /// The modifiers of a modifiers-only binding for dictation or voice editing; nil for a binding with a key, or none.
    private func chord(_ mode: CaptureMode) -> KeyModifiers? {
        let binding = mode == .dictation ? keys.dictation : keys.voiceEdit
        return binding?.isModifierOnly == true ? binding?.modifiers : nil
    }

    private func begin(_ mode: CaptureMode) {
        // fn alone is quick to start. Several modifiers wait longer, as they often begin another shortcut.
        let wait: UInt64 = chord(mode) == [.function] ? 140_000_000 : 300_000_000
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self, self.pending?.mode == mode else { return }
            self.pending = nil; self.held = mode; self.onDown?(mode)
        }
        pending = (mode, task)
    }

    private func cancelPending() { pending?.task.cancel(); pending = nil }
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
/// own are a binding too ("fn", "⌃ ⌥"). Escape gives up.
struct KeyCaptureField: NSViewRepresentable {
    let onHeld: (KeyModifiers) -> Void
    let onCapture: (KeyBinding) -> Void
    let onCancel: () -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onHeld = onHeld; view.onCapture = onCapture; view.onCancel = onCancel
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { view.onHeld = onHeld; view.onCapture = onCapture; view.onCancel = onCancel }

    final class CaptureView: NSView {
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
            let now = KeyModifiers(event.modifierFlags)
            if now.isEmpty {
                if !peak.isEmpty, !keyUsed { onCapture(KeyBinding(modifiers: peak, label: peak.symbols)) }
                peak = []; keyUsed = false
            } else {
                peak.formUnion(now)
            }
            onHeld(now)
        }
        override func keyDown(with event: NSEvent) { take(event) }
        // ⌘ combinations arrive as key equivalents, before any menu can claim them.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else { return false }
            take(event); return true
        }
        private func take(_ event: NSEvent) {
            if event.keyCode == 53 { onCancel(); return }
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
