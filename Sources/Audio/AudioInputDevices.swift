import CoreAudio
import Foundation

/// A microphone the Mac can record from.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public enum Transport: Sendable, Equatable {
        case builtIn, bluetooth, usb, virtual, other
    }

    public let id: AudioDeviceID
    /// Stable across restarts and reconnects, unlike `id`. Use this to remember a choice.
    public let uid: String
    public let name: String
    public let transport: Transport

    public var isBluetooth: Bool { transport == .bluetooth }
}

/// Finds and chooses microphones.
///
/// Bluetooth headsets are a poor default for dictation: switching them to call mode takes about half a second
/// (so the first words are lost) and lowers their playback quality while recording.
public enum AudioInputDevices {
    /// Real microphones. Virtual devices (Teams, Zoom, aggregate) are left out because they can't be relied on.
    public static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap(makeDevice).filter { $0.transport != .virtual }
    }

    public static func systemDefault() -> AudioInputDevice? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return makeDevice(id)
    }

    public static func device(uid: String) -> AudioInputDevice? {
        all().first { $0.uid == uid }
    }

    /// The system default, unless it is a Bluetooth headset. Then the Mac's built-in microphone.
    public static func automatic() -> AudioInputDevice? {
        let fallback = systemDefault()
        guard let fallback, fallback.isBluetooth else { return fallback }
        return all().first { $0.transport == .builtIn } ?? fallback
    }

    /// The device to record from: the user's pick if it is connected, otherwise `automatic()`.
    public static func resolve(preferredUID: String?) -> AudioInputDevice? {
        if let preferredUID, !preferredUID.isEmpty, let chosen = device(uid: preferredUID) { return chosen }
        return automatic()
    }

    // MARK: - Core Audio plumbing

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func makeDevice(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard inputChannelCount(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = string(id, kAudioObjectPropertyName) ?? "Unknown microphone"
        return AudioInputDevice(id: id, uid: uid, name: name, transport: transport(id))
    }

    private static func transport(_ id: AudioDeviceID) -> AudioInputDevice.Transport {
        var address = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
