@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Sums microphone stream(s) into the tap stream inside an aggregate
/// device's IO callback (`--mix`).
///
/// Stream layout: an aggregate's input buffer list contains one buffer per
/// input stream — sub-device (mic) streams first, tap streams last. All
/// streams arrive clock-synced at the aggregate rate as float32, so mixing
/// is a frame-wise sum with clamping; mono mic channels are duplicated
/// across tap channels.
final class StreamMixer {
    private let tapChannels: Int
    private var scratch: AVAudioPCMBuffer?

    init(tapChannels: Int) {
        self.tapChannels = max(1, tapChannels)
    }

    func mixedBuffer(
        from inputData: UnsafePointer<AudioBufferList>, tapFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard let tapBuffer = buffers.last else { return nil }

        let bytesPerFrame = tapChannels * MemoryLayout<Float32>.size
        let frames = Int(tapBuffer.mDataByteSize) / bytesPerFrame
        guard frames > 0,
            let tapSamples = tapBuffer.mData?.assumingMemoryBound(to: Float32.self)
        else { return nil }

        guard let output = scratchBuffer(format: tapFormat, capacity: AVAudioFrameCount(frames)),
            let outputSamples = output.floatChannelData?[0]  // interleaved
        else { return nil }
        output.frameLength = AVAudioFrameCount(frames)

        // Start from the tap signal.
        outputSamples.update(from: tapSamples, count: frames * tapChannels)

        // Sum every mic stream (all buffers except the last) on top.
        for index in 0..<(buffers.count - 1) {
            let micBuffer = buffers[index]
            let micChannels = max(1, Int(micBuffer.mNumberChannels))
            let micFrames = Int(micBuffer.mDataByteSize) / (micChannels * MemoryLayout<Float32>.size)
            guard let micSamples = micBuffer.mData?.assumingMemoryBound(to: Float32.self)
            else { continue }

            let mixFrames = min(frames, micFrames)
            for frame in 0..<mixFrames {
                for channel in 0..<tapChannels {
                    let micChannel = min(channel, micChannels - 1)
                    let index = frame * tapChannels + channel
                    let sum = outputSamples[index] + micSamples[frame * micChannels + micChannel]
                    outputSamples[index] = max(-1.0, min(1.0, sum))
                }
            }
        }
        return output
    }

    private func scratchBuffer(
        format: AVAudioFormat, capacity: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        if let scratch, scratch.frameCapacity >= capacity {
            return scratch
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 4096))
        scratch = buffer
        return buffer
    }
}
