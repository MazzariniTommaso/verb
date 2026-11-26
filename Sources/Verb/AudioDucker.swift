import AppKit
import AudioToolbox
import CoreAudio

/// Turns the Mac's sound down while you dictate, and back up afterwards: music and videos go
/// quiet without stopping. If you change the volume yourself in the meantime, yours stays.
///
/// The output is remembered by its UID, not its identifier: Bluetooth headphones come back with
/// a new identifier every time they reconnect, and macOS gives them the volume they had, the
/// lowered one if they left mid-dictation. The volume to put back is also kept on disk, so a
/// Verb that quit or crashed while the sound was down puts it back at the next launch.
/// Nothing is turned down during a call, when another app uses a microphone or the headphones
/// are in call mode, nor while VoiceOver speaks.
@MainActor final class AudioDucker {
    /// How loud the sound stays while you speak, as a share of your volume.
    static let share: Float32 = 0.4
    /// How far apart two volumes can be and still be the same setting: some outputs round the
    /// volume to their own steps, sixteen of them on AirPods.
    static let step: Float32 = 0.07
    private struct Saved: Codable { let uid: String; let volume: Float32; let lowered: Float32 }
    private var saved: Saved?
    /// The volume moved while it was down, and not because of Verb.
    private var changedByYou = false
    private var watched: (device: AudioDeviceID, listener: AudioObjectPropertyListenerBlock)?
    private static let defaultsKey = "VerbLoweredVolume"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Whether the sound is down because of Verb.
    var isLowered: Bool { saved != nil }

    func duck() {
        guard saved == nil, !NSWorkspace.shared.isVoiceOverEnabled, let device = Self.outputDevice(), let uid = Self.uid(of: device),
              !Self.inCall(output: device), let volume = Self.volume(of: device), volume > 0.02, Self.canSetVolume(of: device) else { return }
        let lowered = volume * Self.share
        guard Self.setVolume(lowered, of: device) else { return }
        let state = Saved(uid: uid, volume: volume, lowered: Self.volume(of: device) ?? lowered)
        saved = state; changedByYou = false
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.defaultsKey) }
        watch(device)
    }

    func restore() {
        guard let saved else { return }
        self.saved = nil
        unwatch()
        defaults.removeObject(forKey: Self.defaultsKey)
        // Only the level Verb set is put back: a volume you chose while dictating is yours.
        guard !changedByYou, let device = Self.device(uid: saved.uid), let current = Self.volume(of: device), abs(current - saved.lowered) <= Self.step else { return }
        _ = Self.setVolume(saved.volume, of: device)
    }

    /// A volume left down by a Verb that quit or crashed mid-dictation goes back up. Called once
    /// at launch, by the app that runs the keys and the microphone.
    func restoreLeftover() {
        guard let data = defaults.data(forKey: Self.defaultsKey), let leftover = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        defaults.removeObject(forKey: Self.defaultsKey)
        guard let device = Self.device(uid: leftover.uid), let current = Self.volume(of: device), abs(current - leftover.lowered) <= Self.step else { return }
        _ = Self.setVolume(leftover.volume, of: device)
    }

    /// Notices a volume change while the sound is down. Verb's own change reads back as the
    /// lowered level, give or take a step; anything further is yours.
    private func watch(_ device: AudioDeviceID) {
        unwatch()
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let saved = self.saved, let current = Self.volume(of: device) else { return }
                if abs(current - saved.lowered) > Self.step { self.changedByYou = true }
            }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, listener) == noErr { watched = (device, listener) }
    }
    private func unwatch() {
        guard let watched else { return }
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        AudioObjectRemovePropertyListenerBlock(watched.device, &address, DispatchQueue.main, watched.listener)
        self.watched = nil
    }

    /// A call is on: another app runs a microphone, or the output is Bluetooth headphones in call
    /// mode, which run at a call's sample rate.
    static func inCall(output device: AudioDeviceID) -> Bool {
        var transport = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            var rate = Float64(0), rateSize = UInt32(MemoryLayout<Float64>.size)
            var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
            if AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate) == noErr, rate > 0, rate < 32000 { return true }
        }
        return otherAppUsesMicrophone()
    }
    private static func otherAppUsesMicrophone() -> Bool {
        var listAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes) == noErr else { return false }
        let own = getpid()
        return processes.contains { process in
            var pid = pid_t(0), pidSize = UInt32(MemoryLayout<pid_t>.size), running = UInt32(0), runningSize = UInt32(MemoryLayout<UInt32>.size)
            var pidAddress = address(kAudioProcessPropertyPID), runningAddress = address(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != own,
                  AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr else { return false }
            return running != 0
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func outputDevice() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }
    private static func uid(of device: AudioDeviceID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    /// The device with this UID now, whatever its identifier.
    private static func device(uid: String) -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString, device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &device) }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
    private static func volume(of device: AudioDeviceID) -> Float32? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }
    private static func canSetVolume(of device: AudioDeviceID) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
    private static func setVolume(_ value: Float32, of device: AudioDeviceID) -> Bool {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var volume = min(max(value, 0), 1)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume) == noErr
    }
}
