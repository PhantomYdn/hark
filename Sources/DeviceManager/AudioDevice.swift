import CoreAudio
import Foundation

/// A physical or virtual audio device known to the CoreAudio HAL.
public struct AudioDevice: Codable, Equatable, Sendable {
    /// Stable unique identifier (use this for `hark -d`).
    public let uid: String
    /// Human-readable device name.
    public let name: String
    /// Number of input channels (0 for output-only devices).
    public let inputChannels: Int
    /// Number of output channels (0 for input-only devices).
    public let outputChannels: Int
    /// Supported nominal sample rates in Hz.
    public let sampleRates: [Double]
    /// True if this is the system default input device.
    public let isDefaultInput: Bool

    /// Transient HAL identifier; excluded from JSON (not stable across reboots).
    public let objectID: UInt32

    enum CodingKeys: String, CodingKey {
        case uid, name, inputChannels, outputChannels, sampleRates, isDefaultInput
    }

    public init(
        uid: String, name: String, inputChannels: Int, outputChannels: Int,
        sampleRates: [Double], isDefaultInput: Bool, objectID: UInt32
    ) {
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRates = sampleRates
        self.isDefaultInput = isDefaultInput
        self.objectID = objectID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        name = try container.decode(String.self, forKey: .name)
        inputChannels = try container.decode(Int.self, forKey: .inputChannels)
        outputChannels = try container.decode(Int.self, forKey: .outputChannels)
        sampleRates = try container.decode([Double].self, forKey: .sampleRates)
        isDefaultInput = try container.decode(Bool.self, forKey: .isDefaultInput)
        objectID = 0
    }
}

/// Which devices to list.
public enum DeviceScope: Sendable {
    case input
    case output
    case all
}

extension DeviceManager {
    /// Lists alive audio devices, optionally filtered to inputs or outputs.
    public static func listDevices(scope: DeviceScope = .all) throws -> [AudioDevice] {
        let deviceIDs = try AudioObjectProperty.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDevices,
            of: AudioDeviceID.self,
            operation: "listing devices"
        )
        let defaultInputID = try? defaultInputDeviceID()

        var devices: [AudioDevice] = []
        for id in deviceIDs {
            guard let device = try? describeDevice(id, defaultInputID: defaultInputID) else {
                continue  // skip devices that fail property reads
            }
            // Exclude devices that have gone away (PRD §6.2: exclude inactive).
            guard isAlive(id) else { continue }
            switch scope {
            case .input: if device.inputChannels > 0 { devices.append(device) }
            case .output: if device.outputChannels > 0 { devices.append(device) }
            case .all: devices.append(device)
            }
        }
        return devices
    }

    /// The system default input device, if any.
    public static func defaultInputDevice() throws -> AudioDevice? {
        let id = try defaultInputDeviceID()
        return try describeDevice(id, defaultInputID: id)
    }

    /// Resolves a device UID to a HAL AudioObjectID.
    public static func deviceID(forUID uid: String) throws -> AudioDeviceID? {
        let devices = try listDevices(scope: .all)
        return devices.first { $0.uid == uid }.map { AudioDeviceID($0.objectID) }
    }

    // MARK: - Internals

    static func defaultInputDeviceID() throws -> AudioDeviceID {
        try AudioObjectProperty.read(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice,
            as: AudioDeviceID.self,
            operation: "reading default input device"
        )
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        guard
            let alive = try? AudioObjectProperty.read(
                id, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self,
                operation: "reading is-alive")
        else { return true }  // property missing -> assume alive
        return alive != 0
    }

    static func describeDevice(
        _ id: AudioDeviceID, defaultInputID: AudioDeviceID?
    ) throws -> AudioDevice {
        let uid = try AudioObjectProperty.readString(
            id, kAudioDevicePropertyDeviceUID, operation: "reading device UID")
        let name =
            (try? AudioObjectProperty.readString(
                id, kAudioObjectPropertyName, operation: "reading device name")) ?? uid

        let sampleRates = ((try? AudioObjectProperty.readArray(
            id, kAudioDevicePropertyAvailableNominalSampleRates,
            of: AudioValueRange.self,
            operation: "reading sample rates")) ?? [])
            .flatMap { range -> [Double] in
                range.mMinimum == range.mMaximum ? [range.mMinimum] : [range.mMinimum, range.mMaximum]
            }
            .reduce(into: [Double]()) { acc, rate in
                if !acc.contains(rate) { acc.append(rate) }
            }
            .sorted()

        return AudioDevice(
            uid: uid,
            name: name,
            inputChannels: channelCount(id, scope: kAudioDevicePropertyScopeInput),
            outputChannels: channelCount(id, scope: kAudioDevicePropertyScopeOutput),
            sampleRates: sampleRates,
            isDefaultInput: defaultInputID == id,
            objectID: id
        )
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectProperty.address(
            kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let listPointer = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let list = UnsafeMutableAudioBufferListPointer(listPointer)
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
