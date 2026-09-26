import AudioToolbox
import CoreAudio

/// Turns the Mac's sound down while you dictate, and back up afterwards: music and videos go
/// quiet without stopping. If you change the volume yourself in the meantime, yours stays.
@MainActor final class AudioDucker {
    /// How loud the sound stays while you speak, as a share of your volume.
    static let share: Float32 = 0.2
    private var saved: (device: AudioDeviceID, volume: Float32, lowered: Float32)?

    func duck() {
        guard saved == nil, let device = Self.outputDevice(), let volume = Self.volume(of: device), volume > 0.02, Self.canSetVolume(of: device) else { return }
        let lowered = volume * Self.share
        guard Self.setVolume(lowered, of: device) else { return }
        saved = (device, volume, lowered)
    }

    func restore() {
        guard let saved else { return }
        self.saved = nil
        // Only the level Verb set is put back: a volume you chose while dictating is yours.
        guard let current = Self.volume(of: saved.device), abs(current - saved.lowered) < 0.02 else { return }
        _ = Self.setVolume(saved.volume, of: saved.device)
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
