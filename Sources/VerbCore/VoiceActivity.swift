import Foundation

/// Finds where speech starts and stops in a live 16 kHz stream. It hears loudness, not
/// words: the speech engine decides what was said. The noise floor is the quietest moment of
/// the last few seconds, so a fan or a café raises the bar and a quiet room lowers it.
public struct VoiceActivity: Sendable {
    /// An utterance, as positions in the stream counted in samples since listening began.
    public struct Segment: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }
    public enum Event: Equatable, Sendable {
        /// Speech began. The position includes a short lead-in, so the first syllable is kept.
        case started(Int)
        /// Still talking: a moment to check what has been said so far.
        case continuing(Segment)
        /// A pause long enough to end the utterance.
        case ended(Segment)
    }

    public let sampleRate: Int
    /// The stream position of the next sample.
    public private(set) var position: Int
    private let frame: Int, leadIn: Int, tail: Int, longest: Int
    private let checkpoints: [Int]
    private var pending: [Float] = []
    private var energies: [Double] = []
    private var energyIndex = 0
    private var loudFrames = 0
    private var utterance: (start: Int, lastVoice: Int, quietFrames: Int, checkpoint: Int)?

    /// Frames of 20 ms. Speech starts after 60 ms above the floor and ends after 0.7 s below it.
    private static let onsetFrames = 3, pauseFrames = 35, floorFrames = 400

    public init(sampleRate: Int = 16000, position: Int = 0, checkpoints: [Double] = [1.0, 1.8, 2.6]) {
        self.sampleRate = sampleRate
        self.position = position
        frame = max(1, sampleRate / 50)
        leadIn = sampleRate / 4
        // A quarter of a second after the last loud frame, so a soft final consonant (the b of "Verb") stays inside.
        tail = sampleRate / 4
        longest = sampleRate * 30
        self.checkpoints = checkpoints.map { Int($0 * Double(sampleRate)) }.sorted()
    }

    /// True between the start of an utterance and the pause that ends it.
    public var speaking: Bool { utterance != nil }

    /// Forgets the utterance in progress but keeps the position and the room's noise floor,
    /// so what was said before a dictation ended never counts afterwards.
    public mutating func restart() { utterance = nil; loudFrames = 0 }

    public mutating func process(_ samples: [Float]) -> [Event] {
        var events: [Event] = []
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= frame {
            var sum: Double = 0
            for value in pending[offset..<(offset + frame)] { sum += Double(value * value) }
            offset += frame
            step(10 * log10(sum / Double(frame) + 1e-12), into: &events)
        }
        pending.removeFirst(offset)
        return events
    }

    /// The quietest frame of the last eight seconds, kept within sensible bounds.
    private var noiseFloor: Double { min(-35, max(-80, energies.min() ?? -65)) }

    private mutating func step(_ energy: Double, into events: inout [Event]) {
        let floor = noiseFloor
        if energies.count < Self.floorFrames { energies.append(energy) } else { energies[energyIndex] = energy }
        energyIndex = (energyIndex + 1) % Self.floorFrames
        let frameStart = position
        position += frame
        guard var current = utterance else {
            loudFrames = energy > max(floor + 9, -55) ? loudFrames + 1 : 0
            guard loudFrames >= Self.onsetFrames else { return }
            let start = max(0, frameStart - (loudFrames - 1) * frame - leadIn)
            utterance = (start: start, lastVoice: position, quietFrames: 0, checkpoint: 0)
            loudFrames = 0
            events.append(.started(start))
            return
        }
        if energy > max(floor + 5, -58) { current.lastVoice = position; current.quietFrames = 0 } else { current.quietFrames += 1 }
        if current.quietFrames >= Self.pauseFrames {
            events.append(.ended(Segment(start: current.start, end: min(position, current.lastVoice + tail))))
            utterance = nil
            return
        }
        if current.checkpoint < checkpoints.count, position - current.start >= checkpoints[current.checkpoint] {
            events.append(.continuing(Segment(start: current.start, end: position)))
            current.checkpoint += 1
        }
        // A very long utterance is cut into pieces, so every check looks at a bounded window.
        if position - current.start >= longest {
            events.append(.ended(Segment(start: current.start, end: position)))
            events.append(.started(position))
            current = (start: position, lastVoice: position, quietFrames: 0, checkpoint: 0)
        }
        utterance = current
    }
}

/// The last few seconds of a stream, addressed by position, so a recording can begin a
/// moment in the past.
public struct SampleRing: Sendable {
    public let capacity: Int
    private var storage: [Float]
    /// The position just after the newest sample.
    public private(set) var end = 0
    /// The oldest position still held.
    public var start: Int { max(0, end - capacity) }

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    public mutating func append(_ samples: [Float]) {
        let skipped = max(0, samples.count - capacity)
        for index in skipped..<samples.count { storage[(end + index) % capacity] = samples[index] }
        end += samples.count
    }

    /// The samples between two positions, limited to what is still held.
    public func samples(from lower: Int, to upper: Int) -> [Float] {
        let from = max(lower, start), to = min(upper, end)
        guard from < to else { return [] }
        let first = from % capacity, count = to - from
        if first + count <= capacity { return Array(storage[first..<(first + count)]) }
        return Array(storage[first...]) + Array(storage[..<(first + count - capacity)])
    }
}
