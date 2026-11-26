import Foundation

/// Which microphone a dictation or a meeting uses, judged from what Core Audio reports.
public enum MicrophoneChoice {
    /// What a microphone is, from how it is connected. The order is the one Verb looks in when
    /// no microphone is chosen, with Bluetooth headphones moved after the Mac when asked.
    public enum Kind: Int, Comparable, Sendable, CaseIterable {
        /// Plugged in: a headset in the jack, a USB or Thunderbolt microphone or interface, a
        /// display's microphone. Close to the mouth, with nothing given up.
        case wired
        /// Bluetooth headphones: close to the mouth, but they play in call quality while their
        /// microphone is open.
        case headset
        /// The Mac's own: clear in a quiet room, far from the mouth in a noisy one.
        case builtIn
        /// An iPhone lent to the Mac (Continuity): it takes seconds to start.
        case phone
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    public struct Device: Equatable, Sendable {
        public let id: String
        /// Nil for a device nobody speaks into.
        public let kind: Kind?
        public init(id: String, kind: Kind?) { self.id = id; self.kind = kind }
        public var isBuiltIn: Bool { kind == .builtIn }
        public var isBluetooth: Bool { kind == .headset }
    }
    public struct Pick: Equatable, Sendable {
        public let id: String
        /// The chosen microphone is missing, and this one stands in for it.
        public let standIn: Bool
    }

    /// A device's kind from its Core Audio transport, or nil for one nobody speaks into:
    /// devices that pass audio between apps (Pro Tools, BlackHole, a video call's own),
    /// aggregates, AirPlay and screen sharing. `external` is the Mac's own input switched to
    /// a headset in the jack.
    public static func kind(transport: UInt32, external: Bool) -> Kind? {
        switch transport {
        case code("bltn"): return external ? .wired : .builtIn
        case code("usb "), code("thun"), code("1394"), code("pci "), code("hdmi"), code("dprt"), code("eavb"): return .wired
        case code("blue"), code("blea"): return .headset
        case code("ccwd"), code("ccwl"): return .phone
        default: return nil
        }
    }
    /// The kinds in the order Verb tries them.
    public static func order(headsetFirst: Bool) -> [Kind] {
        headsetFirst ? [.wired, .headset, .builtIn, .phone] : [.wired, .builtIn, .headset, .phone]
    }

    /// The chosen microphone when it is there. Otherwise the first kind present in `order`;
    /// within a kind, the one macOS uses if it is of that kind. With the lid closed the Mac's
    /// own hears nothing and is passed over. Devices nobody speaks into are taken only when
    /// nothing else is there.
    public static func pick(chosen: String, devices: [Device], systemDefault: String?, headsetFirst: Bool, lidClosed: Bool) -> Pick? {
        if !chosen.isEmpty, devices.contains(where: { $0.id == chosen }) { return Pick(id: chosen, standIn: false) }
        for kind in order(headsetFirst: headsetFirst) where !(lidClosed && kind == .builtIn) {
            let present = devices.filter { $0.kind == kind }
            if let device = present.first(where: { $0.id == systemDefault }) ?? present.first { return Pick(id: device.id, standIn: !chosen.isEmpty) }
        }
        let fallback = devices.first { $0.id == systemDefault } ?? devices.first
        return fallback.map { Pick(id: $0.id, standIn: !chosen.isEmpty) }
    }

    private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

/// What a microphone test heard, from the loudness of each 20 ms: whether the voice stands out
/// from the room enough for speech recognition.
public enum MicrophoneVerdict: Equatable, Sendable {
    /// The voice is well above the room.
    case clear
    /// Usable, with some noise.
    case noisy
    /// The room is nearly as loud as the voice: recognition misses words.
    case tooNoisy
    /// A voice, but faint: too far away, or the input level is low.
    case faint
    /// A quiet room and no voice in it: nothing was said, or the microphone is muted.
    case noVoice
    /// No sound came through at all.
    case silent

    /// `levels` are root-mean-square values of 20 ms pieces, from 0 to 1. The room is the
    /// quietest tenth, the voice the loudest twentieth; the gap between them decides.
    public static func assess(levels: [Float]) -> (verdict: MicrophoneVerdict, voice: Double, room: Double) {
        guard !levels.isEmpty else { return (.silent, -120, -120) }
        let sorted = levels.sorted()
        func decibels(_ value: Float) -> Double { 20 * log10(max(Double(value), 1e-6)) }
        let room = decibels(sorted[sorted.count / 10]), voice = decibels(sorted[min(sorted.count - 1, sorted.count * 95 / 100)])
        let gap = voice - room
        let verdict: MicrophoneVerdict
        if voice < -70 { verdict = .silent }
        else if gap < 6 { verdict = room > -50 ? .tooNoisy : .noVoice }
        else if voice < -45 { verdict = .faint }
        else if gap < 12 { verdict = .tooNoisy }
        else if gap < 20 { verdict = .noisy }
        else { verdict = .clear }
        return (verdict, voice, room)
    }
}

/// How often a microphone may start again after its device changed or stopped. A device that
/// keeps changing, as a Bluetooth headset renegotiating or a driver resetting, is given up on
/// instead of being restarted for ever.
public struct RestartBudget: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var starts: [TimeInterval] = []

    public init(limit: Int = 3, window: TimeInterval = 10) { self.limit = limit; self.window = window }

    /// Whether one more start is allowed at `now`. An allowed start counts against the budget.
    public mutating func allow(at now: TimeInterval) -> Bool {
        starts.removeAll { now - $0 >= window }
        guard starts.count < limit else { return false }
        starts.append(now)
        return true
    }
    /// A new dictation or meeting begins with the whole budget.
    public mutating func reset() { starts = [] }
}
