import XCTest
@testable import VerbCore

final class MicrophoneTests: XCTestCase {
    private let mac = MicrophoneChoice.Device(id: "BuiltInMicrophoneDevice", kind: .builtIn)
    private let airPods = MicrophoneChoice.Device(id: "38-88-A4-E7-6C-AB:input", kind: .headset)
    private let usb = MicrophoneChoice.Device(id: "AppleUSBAudioEngine:Jabra", kind: .wired)
    private let iPhone = MicrophoneChoice.Device(id: "0268AF1B-7B0E-4E26-A672-E02900000003", kind: .phone)
    private let proTools = MicrophoneChoice.Device(id: "Pro Tools Audio Bridge 2-A", kind: nil)

    private func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    func testOnlyMicrophonesSomeoneSpeaksIntoHaveAKind() {
        XCTAssertEqual(MicrophoneChoice.kind(transport: code("bltn"), external: false), .builtIn)
        XCTAssertEqual(MicrophoneChoice.kind(transport: code("bltn"), external: true), .wired, "a headset in the Mac's jack")
        for wired in ["usb ", "thun", "1394", "pci ", "hdmi", "dprt", "eavb"] { XCTAssertEqual(MicrophoneChoice.kind(transport: code(wired), external: false), .wired, wired) }
        XCTAssertEqual(MicrophoneChoice.kind(transport: code("blue"), external: false), .headset)
        XCTAssertEqual(MicrophoneChoice.kind(transport: code("blea"), external: false), .headset)
        XCTAssertEqual(MicrophoneChoice.kind(transport: code("ccwd"), external: false), .phone)
        for virtual in ["virt", "grup", "airp", "rscr", "rstr"] { XCTAssertNil(MicrophoneChoice.kind(transport: code(virtual), external: false), virtual) }
        XCTAssertNil(MicrophoneChoice.kind(transport: 0, external: false))
    }
    func testAChosenMicrophoneIsUsedWhateverIsAround() {
        let devices = [mac, airPods, usb, proTools]
        XCTAssertEqual(MicrophoneChoice.pick(chosen: mac.id, devices: devices, systemDefault: airPods.id, headsetFirst: true, lidClosed: false), .init(id: mac.id, standIn: false))
        XCTAssertEqual(MicrophoneChoice.pick(chosen: proTools.id, devices: devices, systemDefault: mac.id, headsetFirst: false, lidClosed: false), .init(id: proTools.id, standIn: false),
                       "chosen on purpose, even a virtual device is used")
    }
    func testWithNoneChosenTheHierarchyDecides() {
        let all = [iPhone, mac, airPods, usb, proTools]
        XCTAssertEqual(MicrophoneChoice.pick(chosen: "", devices: all, systemDefault: proTools.id, headsetFirst: true, lidClosed: false)?.id, usb.id, "plugged in comes first")
        let wireless = [iPhone, mac, airPods, proTools]
        XCTAssertEqual(MicrophoneChoice.pick(chosen: "", devices: wireless, systemDefault: airPods.id, headsetFirst: true, lidClosed: false)?.id, airPods.id)
        XCTAssertEqual(MicrophoneChoice.pick(chosen: "", devices: wireless, systemDefault: airPods.id, headsetFirst: false, lidClosed: false)?.id, mac.id)
        XCTAssertEqual(MicrophoneChoice.pick(chosen: "", devices: wireless, systemDefault: airPods.id, headsetFirst: false, lidClosed: true)?.id, airPods.id,
                       "with the lid closed the Mac's own microphone hears nothing")
        XCTAssertEqual(MicrophoneChoice.pick(chosen: "", devices: [iPhone, proTools], systemDefault: proTools.id, headsetFirst: true, lidClosed: false)?.id, iPhone.id,
                       "a virtual device is never picked while a real one is there")
        XCTAssertEqual(MicrophoneChoice.pick(chosen: "", devices: [proTools], systemDefault: proTools.id, headsetFirst: true, lidClosed: false)?.id, proTools.id)
    }
    func testWithinAKindTheOneMacOSUsesWins() {
        let jack = MicrophoneChoice.Device(id: "BuiltInHeadphoneInputDevice", kind: .wired)
        XCTAssertEqual(MicrophoneChoice.pick(chosen: "", devices: [usb, jack, mac], systemDefault: jack.id, headsetFirst: false, lidClosed: false)?.id, jack.id)
        XCTAssertEqual(MicrophoneChoice.pick(chosen: "", devices: [usb, jack, mac], systemDefault: mac.id, headsetFirst: false, lidClosed: false)?.id, usb.id)
    }
    func testAMissingMicrophoneIsStoodInForAndSaidSo() {
        XCTAssertEqual(MicrophoneChoice.pick(chosen: usb.id, devices: [mac, airPods], systemDefault: airPods.id, headsetFirst: false, lidClosed: false), .init(id: mac.id, standIn: true))
        XCTAssertNil(MicrophoneChoice.pick(chosen: mac.id, devices: [], systemDefault: nil, headsetFirst: false, lidClosed: false))
    }
    /// Levels of a test: `room` for most of it, `voice` for a stretch, both in dBFS.
    private func levels(room: Double, voice: Double, spoken: Int = 60, total: Int = 200) -> [Float] {
        (0..<total).map { Float(pow(10, ($0 < spoken ? voice : room) / 20)) }
    }
    func testAMicrophoneTestTellsAVoiceFromTheRoom() {
        XCTAssertEqual(MicrophoneVerdict.assess(levels: levels(room: -66, voice: -36)).verdict, .clear, "a quiet room, as on the day dictation worked")
        XCTAssertEqual(MicrophoneVerdict.assess(levels: levels(room: -50, voice: -34)).verdict, .noisy)
        XCTAssertEqual(MicrophoneVerdict.assess(levels: levels(room: -31, voice: -23)).verdict, .tooNoisy, "the room nearly as loud as the voice, as when recognition found no words")
        XCTAssertEqual(MicrophoneVerdict.assess(levels: levels(room: -30, voice: -28)).verdict, .tooNoisy)
        XCTAssertEqual(MicrophoneVerdict.assess(levels: levels(room: -75, voice: -52)).verdict, .faint)
        XCTAssertEqual(MicrophoneVerdict.assess(levels: levels(room: -68, voice: -66)).verdict, .noVoice)
        XCTAssertEqual(MicrophoneVerdict.assess(levels: levels(room: -110, voice: -110)).verdict, .silent)
        XCTAssertEqual(MicrophoneVerdict.assess(levels: []).verdict, .silent)
        let heard = MicrophoneVerdict.assess(levels: levels(room: -66, voice: -36))
        XCTAssertEqual(heard.voice, -36, accuracy: 0.5); XCTAssertEqual(heard.room, -66, accuracy: 0.5)
    }
    func testADeviceThatKeepsChangingIsGivenUpOn() {
        var budget = RestartBudget(limit: 3, window: 10)
        XCTAssertTrue(budget.allow(at: 0)); XCTAssertTrue(budget.allow(at: 0.4)); XCTAssertTrue(budget.allow(at: 0.8))
        XCTAssertFalse(budget.allow(at: 1.2), "a fourth restart within ten seconds is a loop")
        XCTAssertFalse(budget.allow(at: 9.9))
        XCTAssertTrue(budget.allow(at: 10.5), "a change long after the last ones is a new one")
        budget.reset()
        XCTAssertTrue(budget.allow(at: 10.6)); XCTAssertTrue(budget.allow(at: 10.7))
    }
}
