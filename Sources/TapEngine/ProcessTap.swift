import CoreAudio
import Foundation

/// What a process tap captures.
public enum TapScope: Sendable {
    /// All system audio, minus the given process objects.
    case system(excluding: [AudioObjectID])
    /// Only the given process objects (stereo mixdown).
    case processes([AudioObjectID])
}

/// A Core Audio process tap (macOS 14.4+): an HAL object that exposes the
/// audio rendered by one or more processes. Read through an aggregate
/// device (see `SystemCaptureSession`); destroyed explicitly.
final class ProcessTap {
    let tapID: AudioObjectID
    /// UID used to reference this tap from an aggregate device's tap list.
    let uid: String
    /// Stream format the tap produces (typically float32 stereo).
    let format: AudioStreamBasicDescription

    private var destroyed = false

    init(scope: TapScope) throws {
        let description: CATapDescription
        switch scope {
        case .system(let excluded):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .processes(let included):
            description = CATapDescription(stereoMixdownOfProcesses: included)
        }
        // Private: invisible to other processes' device lists.
        // Unmuted: tapped audio keeps playing on the user's output device.
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "hark-tap-\(UUID().uuidString)"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw TapEngineError.tapCreationFailed(status)
        }
        self.tapID = newTapID

        do {
            self.uid = try AudioObjectProperty.readTapString(newTapID, kAudioTapPropertyUID)
            self.format = try AudioObjectProperty.readTapFormat(newTapID)
        } catch {
            AudioHardwareDestroyProcessTap(newTapID)
            throw error
        }
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyProcessTap(tapID)
    }

    deinit {
        destroy()
    }
}

/// Local HAL property helpers (TapEngine keeps no dependency on
/// DeviceManager's internal helpers).
enum AudioObjectProperty {
    static func readTapString(
        _ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let string = value else {
            throw TapEngineError.tapPropertyReadFailed(status)
        }
        return string as String
    }

    static func readTapFormat(_ objectID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw TapEngineError.tapPropertyReadFailed(status)
        }
        return format
    }
}
