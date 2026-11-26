import AppKit
import SwiftUI
import VerbCore

@MainActor final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
