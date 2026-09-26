import AppKit
import QuartzCore
import SwiftUI

/// Measures how often the overlay's ink is redrawn on this Mac's display, in the same kind of
/// panel the overlay uses:
///
///     open -n -g release/Verb.app --args --measure-frames /path/to/result.txt
///
/// A small stroke shows at the bottom of the screen for three seconds, fed with made-up levels
/// in 100 ms bursts, as the microphone delivers them. It never touches the microphone, the
/// keyboard or Verb's data. The frame rates are written to the file, and Verb quits.
@MainActor enum FrameProbe {
    static func run(output: URL) {
        let meter = LevelMeter(), counter = FrameCounter()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 160, height: 40)
        let panel = OverlayPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 38, width: size.width, height: size.height),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating; panel.ignoresMouseEvents = true
        // Like the overlay, it shows on the current space, full-screen ones included.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ProbeView(meter: meter, counter: counter))
        panel.orderFrontRegardless()
        var burst = 0
        let feeder = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                burst += 1
                meter.push((0..<10).map { index in Float(0.5 + 0.4 * sin(Double(burst * 10 + index) * 0.2)) }, at: Date().timeIntervalSinceReferenceDate)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            feeder.invalidate()
            let report = String(format: "display: %@, up to %d Hz\nink redraws per second: %.0f\npanel visible: %@\n",
                                screen.localizedName, screen.maximumFramesPerSecond, counter.rate, panel.occlusionState.contains(.visible) ? "yes" : "no")
            try? report.write(to: output, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

@MainActor private final class FrameCounter {
    var stamps: [Double] = []
    /// Frames per second after the first half second, once the panel has settled.
    var rate: Double {
        let settled = stamps.filter { $0 > (stamps.first ?? 0) + 0.5 }
        guard let first = settled.first, let last = settled.last, last > first else { return 0 }
        return Double(settled.count - 1) / (last - first)
    }
}

private struct ProbeView: View {
    let meter: LevelMeter
    let counter: FrameCounter
    var body: some View {
        ZStack {
            InkStroke(meter: meter).frame(width: 140, height: 24)
            // The same schedule as the stroke's, counted.
            TimelineView(.animation) { timeline in
                let moment = timeline.date.timeIntervalSinceReferenceDate
                Canvas { _, _ in _ = moment; counter.stamps.append(CACurrentMediaTime()) }
            }
        }
        .padding(8)
        .background(Palette.surfaceRaised, in: Capsule())
    }
}
