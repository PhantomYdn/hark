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
        let converter: PCMStreamConverter
        do {
            converter = try PCMStreamConverter(
                inputFormat: source.processingFormat, outputFormat: format)
        } catch let error as TapEngineError {
            throw HarkError.software(error.description)
        }
        let chunkFrames: AVAudioFrameCount = 32768
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat, frameCapacity: chunkFrames)
        else {
            throw HarkError.software("failed to allocate read buffer")
        }
        do {
            // read(into:) at EOF throws nilError on current macOS; bound by
            // framePosition instead.
            while source.framePosition < source.length {
                try source.read(into: buffer, frameCount: chunkFrames)
                if buffer.frameLength == 0 { break }
                if let data = converter.convert(buffer) {
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
