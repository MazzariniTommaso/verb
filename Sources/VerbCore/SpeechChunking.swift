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
