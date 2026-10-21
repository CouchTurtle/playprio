import CoreAudio
import os

/// Notices when the sound moves off headphones (unplugged, out of range, AirPods back in
/// their case or taken by the iPhone), so the music doesn't carry on from the speakers.
/// Headphones here: Bluetooth and USB outputs, and the built-in headphone jack.
final class HeadphoneWatcher {
    private static let log = Logger(subsystem: "local.PlayPrio", category: "Headphones")

    /// Called on the main thread when the default output moves from headphones to anything else.
    var onDisconnect: () -> Void = {}

    private var output = AudioObjectID(kAudioObjectUnknown)
    private var onHeadphones = false
    /// Kept so the same block can be removed from a device again.
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.update() }

    func start() {
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        update()
    }

    private func update() {
        let device = Self.defaultOutput
        if device != output {
            // Intel Macs switch to the headphone jack on the same device: follow its data source too.
            var address = Self.dataSourceAddress
            AudioObjectRemovePropertyListenerBlock(output, &address, .main, listener)
            AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
            output = device
        }
        let wasOnHeadphones = onHeadphones
        onHeadphones = Self.isHeadphones(device)
        guard wasOnHeadphones, !onHeadphones else { return }
        Self.log.notice("headphones gone, now \(Self.name(of: device), privacy: .public)")
        onDisconnect()
    }

    // MARK: Devices

    static var defaultOutput: AudioObjectID {
        AudioProperty.defaultOutput ?? AudioObjectID(kAudioObjectUnknown)
    }

    static func isHeadphones(_ device: AudioObjectID) -> Bool {
        switch AudioProperty.read(device, kAudioDevicePropertyTransportType, as: UInt32.self) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return true
        case kAudioDeviceTransportTypeBuiltIn:
            // The jack is its own device on Apple silicon ("External Headphones"), a data
            // source of the built-in output on Intel. Either way its data source is 'hdpn'.
            return AudioProperty.read(device, kAudioDevicePropertyDataSource, as: UInt32.self, scope: kAudioDevicePropertyScopeOutput)
                == 0x6864_706E // 'hdpn'
                || AudioProperty.string(device, kAudioDevicePropertyDeviceUID)?.contains("Headphone") == true
        default:
            return false
        }
    }

    static func name(of device: AudioObjectID) -> String {
        AudioProperty.string(device, kAudioObjectPropertyName) ?? "no output"
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static var dataSourceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
}
