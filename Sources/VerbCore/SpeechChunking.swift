import Foundation

/// Bounded windows with boundaries near quiet points. Every sample belongs to exactly one chunk.
public enum SpeechChunking {
    public static func ranges(samples: [Float], sampleRate: Int) -> [Range<Int>] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let maximum = sampleRate * 28, search = sampleRate * 5, window = max(1, sampleRate / 50)
        var start = 0, result: [Range<Int>] = []
        while samples.count - start > maximum {
            let upper = start + maximum
            var best = upper, lowest = Double.infinity
            for offset in stride(from: upper - search, through: upper - window, by: window) {
                let energy = samples[offset..<(offset + window)].reduce(0.0) { $0 + Double($1 * $1) }
                if energy <= lowest { lowest = energy; best = offset + window / 2 }
            }
            result.append(start..<best); start = best
        }
        if start < samples.count { result.append(start..<samples.count) }
        return result
    }
}

/// How the live preview reads a recording: short parts, so the words change often.
public enum LivePreviewCut {
    /// The part still being spoken is read again at every tick; past this length the older
    /// words settle, so what the model reads stays short and fast.
    public static let window = 16000 * 3
    /// Where to settle the part not yet settled, as samples from its start, or nil while it is short.
    /// The cut falls on the quietest 20 ms between a second in and 0.4 s before the end, so
    /// words are rarely split.
    public static func settle(_ samples: ArraySlice<Float>, sampleRate: Int = 16000) -> Int? {
        let maximum = sampleRate * 3, frame = max(1, sampleRate / 50)
        guard samples.count > maximum else { return nil }
        let base = samples.startIndex, lower = sampleRate, upper = samples.count - sampleRate * 2 / 5 - frame
        guard upper > lower else { return nil }
        var best = upper, lowest = Double.infinity
        for offset in stride(from: lower, through: upper, by: frame) {
            let energy = samples[(base + offset)..<(base + offset + frame)].reduce(0.0) { $0 + Double($1 * $1) }
            if energy <= lowest { lowest = energy; best = offset + frame / 2 }
        }
        return best
    }
}
