import CoreAudio

/// Reading Core Audio properties: the few values PlayPrio needs of devices and processes.
enum AudioProperty {
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        read(object, selector, as: Unmanaged<CFString>.self)?.takeRetainedValue() as String?
    }

    /// The output the volume keys and Control Center act on.
    static var defaultOutput: AudioObjectID? {
        let device = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
        return device == kAudioObjectUnknown ? nil : device
    }
}
