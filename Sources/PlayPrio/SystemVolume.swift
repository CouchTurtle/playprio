import AudioToolbox
import CoreAudio

/// The Mac's output volume, the one the volume keys change: that of the default output device.
enum SystemVolume {
    /// 0…1, or nil when the device has no volume of its own (some HDMI and USB outputs).
    static var level: Float? {
        AudioProperty.defaultOutput.flatMap {
            AudioProperty.read($0, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, as: Float32.self, scope: kAudioDevicePropertyScopeOutput)
        }
    }

    static var isMuted: Bool {
        AudioProperty.defaultOutput.flatMap {
            AudioProperty.read($0, kAudioDevicePropertyMute, as: UInt32.self, scope: kAudioDevicePropertyScopeOutput)
        }.map { $0 != 0 } ?? false
    }

    /// Sets the volume, and unmutes when it's above zero, like the volume keys.
    @discardableResult
    static func set(_ level: Float) -> Bool {
        guard let device = AudioProperty.defaultOutput else { return false }
        var address = volumeAddress
        var settable: DarwinBoolean = false
        var value = Float32(min(max(level, 0), 1))
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue,
              AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        else { return false }
        var mute = muteAddress
        if value > 0, isMuted, AudioObjectHasProperty(device, &mute) {
            var off = UInt32(0)
            AudioObjectSetPropertyData(device, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
        }
        return true
    }

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
}
