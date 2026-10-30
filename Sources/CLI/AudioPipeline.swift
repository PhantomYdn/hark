@preconcurrency import AVFoundation
import Encoders
import Foundation
import TapEngine

/// Shared decode/convert plumbing for `convert` and `transcribe`.
enum AudioPipeline {
    /// PCM format expected by whisper.cpp: 16 kHz mono 16-bit.
    static let whisperFormat = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    /// Opens an audio file for reading with friendly errors.
    static func openForReading(_ path: String) throws -> AVAudioFile {
        guard FileManager.default.fileExists(atPath: path) else {
            throw HarkError.noInput("no such file: \(path)")
        }
        do {
            return try AVAudioFile(forReading: URL(fileURLWithPath: path))
        } catch {
            throw HarkError.noInput(
                "cannot read '\(path)' as audio: \(error.localizedDescription)")
        }
    }

    /// Decodes `source` into `sink`, converting to `format`. Finalizes the
    /// sink on success.
    static func decode(_ source: AVAudioFile, to sink: AudioSink, format: PCMFormat) throws {
        let sourceFormat = source.processingFormat
        // Asked to fold several channels into one, AVAudioConverter keeps
        // channel 0 and drops the rest, so a file with speech only on the right
        // channel decodes as silence. Average the channels ourselves and hand
        // the converter a mono stream.
        let needsFold = format.channels == 1 && sourceFormat.channelCount > 1
        let monoFormat: AVAudioFormat? =
            needsFold && sourceFormat.commonFormat == .pcmFormatFloat32
            ? AVAudioFormat(standardFormatWithSampleRate: sourceFormat.sampleRate, channels: 1)
            : nil
        if needsFold, monoFormat == nil {
            // Averaging reads float samples, so a non-float32 decode falls back
            // to the converter's channel-0 pick. Say so instead of quietly
            // dropping the other channels.
            Log.verbose(
                "\(sourceFormat.channelCount)-channel input is not float32; "
                    + "folding to mono keeps channel 0 only")
        }
        let converter: PCMStreamConverter
        do {
            converter = try PCMStreamConverter(
                inputFormat: monoFormat ?? sourceFormat, outputFormat: format)
        } catch let error as TapEngineError {
            throw HarkError.software(error.description)
        }
        let chunkFrames: AVAudioFrameCount = 32768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames)
        else {
            throw HarkError.software("failed to allocate read buffer")
        }
        let monoBuffer = try monoFormat.map { format -> AVAudioPCMBuffer in
            guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
                throw HarkError.software("failed to allocate downmix buffer")
            }
            return mono
        }
        do {
            // read(into:) at EOF throws nilError on current macOS; bound by
            // framePosition instead.
            while source.framePosition < source.length {
                try source.read(into: buffer, frameCount: chunkFrames)
                if buffer.frameLength == 0 { break }
                var chunk = buffer
                if let monoBuffer {
                    downmixToMono(buffer, into: monoBuffer)
                    chunk = monoBuffer
                }
                if let data = converter.convert(chunk) {
                    try sink.write(data)
                }
            }
            if let tail = converter.finish() {
                try sink.write(tail)
            }
            try sink.finalize()
        } catch let error as HarkError {
            throw error
        } catch {
            throw HarkError.ioError("conversion failed: \(error)")
        }
    }

    /// Averages every channel of `source` into the single channel of
    /// `destination`. Both buffers must be Float32. Reads the channels
    /// explicitly — interleaved or not — instead of trusting AVAudioConverter's
    /// channel folding, which keeps channel 0 and discards the rest. Averaging
    /// (rather than summing) keeps identical channels at their original level
    /// and cannot clip.
    static func downmixToMono(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer) {
        let frames = Int(source.frameLength)
        guard frames > 0, let input = source.floatChannelData,
            let output = destination.floatChannelData
        else {
            // Claim no frames rather than advertise a length we did not write:
            // the destination buffer is reused per chunk, so a length without
            // samples hands the converter the previous chunk again.
            destination.frameLength = 0
            return
        }
        destination.frameLength = AVAudioFrameCount(frames)
        let channels = Int(source.format.channelCount)
        let interleaved = source.format.isInterleaved
        let scale = 1.0 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += interleaved ? input[0][frame * channels + channel] : input[channel][frame]
            }
            output[0][frame] = sum * scale
        }
    }

    /// Decodes any readable audio file to a whisper-ready temporary WAV.
    /// Caller is responsible for deleting the returned file.
    static func normalizeFileForWhisper(_ path: String) throws -> URL {
        let source = try openForReading(path)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("hark-norm-\(UUID().uuidString).wav")
        let writer = try WAVFileWriter(destination: .file(target), format: whisperFormat)
        let sink = WAVSink(writer: writer, label: target.path)
        try decode(source, to: sink, format: whisperFormat)
        return target
    }
}
