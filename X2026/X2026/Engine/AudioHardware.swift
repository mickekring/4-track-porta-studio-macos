import CoreAudio
import Foundation

/// Small questions for Core Audio about the Mac's sound devices.
nonisolated enum AudioHardware {
    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func number(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var where_ = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        var where_ = address(selector, scope, element)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &where_, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let text = value.takeRetainedValue() as String
        return text.isEmpty ? nil : text
    }

    static func scope(input: Bool) -> AudioObjectPropertyScope {
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let device = number(AudioObjectID(kAudioObjectSystemObject), selector), device != kAudioObjectUnknown else {
            return nil
        }
        return device
    }

    static func name(of device: AudioDeviceID) -> String {
        string(device, kAudioObjectPropertyName) ?? "Audio device"
    }

    static func channelCount(of device: AudioDeviceID, input: Bool) -> Int {
        var where_ = address(kAudioDevicePropertyStreamConfiguration, scope(input: input))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &where_, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The name printed next to a socket, if the driver knows one.
    static func channelName(of device: AudioDeviceID, input: Bool, channel: Int) -> String? {
        string(device, kAudioObjectPropertyElementName, scope(input: input), AudioObjectPropertyElement(channel + 1))
    }

    /// Asks for a small I/O buffer so that monitoring through the machine
    /// feels immediate. The driver is free to give us something else.
    static func requestBuffer(frames: UInt32, on device: AudioDeviceID) {
        var where_ = address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    static func bufferFrames(of device: AudioDeviceID) -> Int {
        Int(number(device, kAudioDevicePropertyBufferFrameSize) ?? 512)
    }

    /// Frames between the HAL's timeline and the converter, one way:
    /// device latency + safety offset + the first stream's latency.
    static func hardwareLatency(of device: AudioDeviceID, input: Bool) -> Int {
        let side = scope(input: input)
        var total = Int(number(device, kAudioDevicePropertyLatency, side) ?? 0)
        total += Int(number(device, kAudioDevicePropertySafetyOffset, side) ?? 0)

        var where_ = address(kAudioDevicePropertyStreams, side)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &where_, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &streams) == noErr, let first = streams.first {
                total += Int(number(first, kAudioStreamPropertyLatency) ?? 0)
            }
        }
        return total
    }

    /// True for a device that reaches the Mac over Bluetooth.
    static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        guard let transport = number(device, kAudioDevicePropertyTransportType) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func sampleRate(of device: AudioDeviceID) -> Double {
        var where_ = address(kAudioDevicePropertyNominalSampleRate)
        var value = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func allDevices() -> [AudioDeviceID] {
        var where_ = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    /// Looks a device up by (part of) its name. Used by the loopback self-test.
    static func device(named needle: String) -> AudioDeviceID? {
        allDevices().first { name(of: $0).localizedCaseInsensitiveContains(needle) }
    }
}
