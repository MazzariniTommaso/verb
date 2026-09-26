import AppKit
import VerbCore

/// Walks the welcome and the tour in a real window, kept off screen so it takes no focus, with
/// a throwaway profile and no microphone, keyboard tap or model:
///
///     .build/release/Verb --check-welcome /path/to/result.txt
///
/// It checks that the practice sheet takes the cursor, ticks the gestures written into it and
/// keeps its words between pages; that every stop of the tour, after the welcome and from the
/// Help menu, finds what it points at; and that finishing is remembered. How the pages look is
/// for `--render-snapshots DIR --only welcome,tour`: SwiftUI builds no accessibility tree to read
/// while no assistive app is running. What happened is written to the file, and Verb quits.
@MainActor enum WelcomeCheck {
    static func run(_ delegate: AppDelegate, output: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verb-welcome-check-" + UUID().uuidString, isDirectory: true)
        guard let model = try? AppModel(dataDirectory: root, services: false) else { NSApp.terminate(nil); return }
        delegate.model = model
        model.microphoneGranted = true; model.accessibilityGranted = false; model.speechInstalled = true
        let window = delegate.makeMainWindow(model)
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        var lines: [String] = [], failures = 0
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            if !passed { failures += 1 }
            lines.append((passed ? "ok    " : "FAIL  ") + label + (detail.isEmpty ? "" : " · " + detail))
        }
        func after(_ seconds: Double, _ step: @escaping @MainActor () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(step) } }
        func finish() {
            lines.append(failures == 0 ? "All checks passed." : "\(failures) checks failed.")
            try? lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
            NSApp.terminate(nil)
        }
        /// One stop: drawn, on its page, and pointing inside the window (or at nothing, for the menu bar).
        func checkStop(_ index: Int) {
            let stop = model.tourStops[index]
            let reached = TourLayer.reached[index] ?? nil
            let drawn = TourLayer.reached.keys.contains(index)
            if stop.target == nil { check("tour stop \(index + 1): menu bar, in the middle", drawn && reached == nil && model.page == stop.page); return }
            let inside = reached.map { window.contentView?.bounds.insetBy(dx: -8, dy: -8).contains($0) == true } ?? false
            let name = stop.target == .footer ? "footer" : stop.target == .words ? "Dictionary, Snippets, Transforms" : stop.page.rawValue
            check("tour stop \(index + 1): \(name)", drawn && inside && model.page == stop.page, reached.map { "at \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nothing found")
        }
        func walkTour(_ index: Int) {
            after(0.6) {
                if index == 0 {
                    check("welcome gives way to the tour", model.welcome == nil && model.tourStop == 0 && model.page == .home)
                    check("after Ready the tour leaves out the menu bar", model.tourStops.count == TourStop.all.count - 1 && model.tourStops.allSatisfy { $0.target != nil }, "\(model.tourStops.count) stops")
                }
                checkStop(index)
                model.moveTour(to: index + 1)
                if model.tourStop != nil { walkTour(index + 1); return }
                after(0.5) {
                    check("last Next ends the tour", model.tourStop == nil && model.page == .home)
                    let saved = (try? JSONStore.load(Settings.self, from: model.paths.settings, fallback: Settings()))?.onboardingComplete == true
                    check("finishing is remembered", saved)
                    model.startWelcome()
                    after(0.4) {
                        check("the welcome opens again", model.welcome == .hello && model.tourStop == nil)
                        // From the Help menu the tour ends with the menu bar, in the middle of the window.
                        model.startTour()
                        check("from Help the tour has every stop", model.welcome == nil && model.tourStops == TourStop.all, "\(model.tourStops.count) stops")
                        model.moveTour(to: TourStop.all.count - 1)
                        after(0.6) {
                            checkStop(TourStop.all.count - 1)
                            model.endTour()
                            finish()
                        }
                    }
                }
            }
        }

        model.welcome = .hello
        after(0.8) {
            model.welcome = .practice
            after(0.9) {
                let responder = window.firstResponder
                check("practice sheet takes the cursor", responder is NSTextView, responder.map { String(describing: type(of: $0)) } ?? "nothing")
                check("Verb writes into the practice sheet", model.noteEditor?.isPractice == true)
                // Three dictations as run() hands them over: held, hands-free, a voice edit.
                model.noteEditor?.insert("Ci vediamo mercoledì alle tre.")
                model.sheetWriting = SheetWriting(mode: .dictation, handsFree: false, text: "Ci vediamo mercoledì alle tre.")
                after(0.4) {
                    check("held dictation ticked", WelcomeView.ticked == [.hold], "\(WelcomeView.ticked.map(\.rawValue).sorted())")
                    check("sheet holds the words", (model.noteEditor?.text ?? "") == "Ci vediamo mercoledì alle tre.", model.noteEditor?.text ?? "none")
                    model.sheetWriting = SheetWriting(mode: .dictation, handsFree: true, text: "Una prova.")
                    after(0.4) {
                        check("hands-free ticked", WelcomeView.ticked == [.hold, .handsFree], "\(WelcomeView.ticked.map(\.rawValue).sorted())")
                        model.sheetWriting = SheetWriting(mode: .command, handsFree: false, text: "Una prova formale.")
                        after(0.4) {
                            check("voice edit ticked", WelcomeView.ticked == Set(PracticeGesture.allCases), "\(WelcomeView.ticked.map(\.rawValue).sorted())")
                            // Leaving the sheet and coming back keeps what was written and ticked.
                            model.welcome = .ready
                            after(0.5) {
                                model.welcome = .practice
                                after(0.6) {
                                    check("the sheet keeps its words between pages", (model.noteEditor?.text ?? "") == "Ci vediamo mercoledì alle tre.", model.noteEditor?.text ?? "none")
                                    model.welcome = .ready
                                    after(0.5) {
                                        check("practice sheet let go on the next page", model.noteEditor == nil)
                                        model.finishWelcome(tour: true)
                                        walkTour(0)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
