import AVFoundation
import CoreAudio
import Foundation
import VerbCore
import VerbEngine

/// Opens a microphone the way Verb does, for a few seconds, and says what came through: the
/// device and its format, how long it took to start and to deliver, how loud it was, and whether
/// Bluetooth headphones changed their sound while it listened, as they do when switched to call
/// quality. Prints PASS or FAIL for each, and exits with 1 on a failure.
enum MicrophoneCheck {
    static func run(_ arguments: [String]) async throws {
        let chosen = arguments.first.map { $0 == "system" ? "" : $0 } ?? ""
        let seconds = arguments.count > 1 ? Double(arguments[1]) ?? 3 : 3
        let defaultID = Microphones.systemDefault()?.id
        for device in Microphones.list() {
            print("input \(device.deviceID)\t\(device.name)\t\(device.isBuiltIn ? "built-in" : device.isBluetooth ? "bluetooth" : "other")\t\(device.id == defaultID ? "system default" : "")")
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw VerbError("Microphone access is off for the app running this check.") }
        guard let pick = Microphones.pick(chosen, preferBuiltIn: true) else { throw VerbError("No microphone is available.") }
        print("using \(pick.device.name)\(pick.standIn ? " (standing in for the chosen one)" : "")")

        let before = bluetoothOutputs()
        let tally = Tally()
        let opened = Date()
        let input = try MicrophoneInput(pick.device) { buffer in tally.add(buffer) }
        input.onChange = { change in tally.changed(change) }
        try input.start()
        let startup = Date().timeIntervalSince(opened)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let during = bluetoothOutputs()
        input.stop()

        let result = tally.result
        print(String(format: "format %.0f Hz, %d ch · started in %.0f ms · first audio after %@ · %d buffers, %.2f s of audio · peak %.4f · rms %.5f",
                     input.format.sampleRate, input.format.channelCount, startup * 1000,
                     result.first.map { String(format: "%.0f ms", $0.timeIntervalSince(opened) * 1000) } ?? "never", result.buffers,
                     Double(result.frames) / input.format.sampleRate, result.peak, result.rms))
        for (id, sound) in before { print("bluetooth output \(id): \(sound) before, \(during[id] ?? "gone") while listening") }
        var failed = false
        func verdict(_ passed: Bool, _ what: String) { print("\(passed ? "PASS" : "FAIL"): \(what)"); failed = failed || !passed }
        verdict(result.buffers > 0, "audio arrived")
        verdict(abs(Double(result.frames) / input.format.sampleRate - seconds) < seconds * 0.15, "about \(seconds) s of audio at the device's own rate")
        verdict(result.peak > 0.00001, "the microphone is not silent")
        verdict(result.changes.isEmpty, "the device stayed as it was\(result.changes.isEmpty ? "" : ": \(result.changes)")")
        if !pick.device.isBluetooth { verdict(before == during, "Bluetooth headphones kept their sound") }
        if failed { exit(1) }
    }

    /// Each Bluetooth output and its sound: rate and channels, which drop for call quality.
    static func bluetoothOutputs() -> [AudioDeviceID: String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        var sounds: [AudioDeviceID: String] = [:]
        for device in devices {
            var transport = UInt32(0), rate = Float64(0), bytes = UInt32(MemoryLayout<UInt32>.size), rateBytes = UInt32(MemoryLayout<Float64>.size)
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &bytes, &transport)
            guard transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { continue }
            var layout = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var listSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &layout, 0, nil, &listSize) == noErr, listSize > 0 else { continue }
            let list = UnsafeMutableRawPointer.allocate(byteCount: Int(listSize), alignment: 16)
            defer { list.deallocate() }
            guard AudioObjectGetPropertyData(device, &layout, 0, nil, &listSize, list) == noErr else { continue }
            let channels = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
            guard channels > 0 else { continue }
            AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateBytes, &rate)
            sounds[device] = "\(Int(rate)) Hz \(channels) ch"
        }
        return sounds
    }

    final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers = 0, frames = 0, peak: Float = 0, squares: Double = 0, first: Date?, changes: [MicrophoneInput.Change] = []
        func add(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            var loudest: Float = 0, sum: Double = 0
            for index in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(channel[index])); sum += Double(channel[index] * channel[index]) }
            lock.lock(); defer { lock.unlock() }
            buffers += 1; frames += Int(buffer.frameLength); peak = max(peak, loudest); squares += sum
            if first == nil { first = Date() }
        }
        func changed(_ change: MicrophoneInput.Change) { lock.lock(); changes.append(change); lock.unlock() }
        var result: (buffers: Int, frames: Int, peak: Float, rms: Double, first: Date?, changes: [MicrophoneInput.Change]) {
            lock.lock(); defer { lock.unlock() }
            return (buffers, frames, peak, frames > 0 ? (squares / Double(frames)).squareRoot() : 0, first, changes)
        }
    }
}
