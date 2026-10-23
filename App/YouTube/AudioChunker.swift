import AVFoundation
import Foundation

enum AudioChunkerError: LocalizedError {
    case noAudioTrack
    case unreadable
    case encoderUnavailable

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "El archivo descargado no tiene pista de audio."
        case .unreadable: return "No se pudo leer el audio descargado."
        case .encoderUnavailable: return "No se pudo convertir el audio para transcribirlo."
        }
    }
}

/// Turns the downloaded audio (or the audio track of a video) into 16 kHz mono AAC parts
/// that fit Groq's upload limit (25 MB). Whisper downsamples to 16 kHz mono anyway, so the
/// conversion loses nothing for the transcription.
enum AudioChunker {
    struct Chunk: Sendable {
        var url: URL
        /// Where the part starts in the original audio, in seconds.
        var offset: Double
    }

    /// 30 minutes at 32 kbit/s is about 7 MB per part.
    static let chunkDuration: Double = 30 * 60
    private static let sampleRate = 16_000
    /// Groq's upload limit on the free tier, with some margin for the multipart body.
    static let uploadLimit: Int64 = 24 * 1_000_000

    static func split(_ source: URL, into folder: URL, duration: Double?,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> [Chunk] {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioChunkerError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioChunkerError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioChunkerError.unreadable }
        defer { if reader.status == .reading { reader.cancelReading() } }

        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var chunks: [Chunk] = []
        var writer: ChunkWriter?
        var firstTime: Double?
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            let seconds = time.isNumeric ? time.seconds : 0
            let start = firstTime ?? seconds
            firstTime = start
            if writer == nil || seconds - writer!.start >= chunkDuration {
                try await writer?.finish()
                let url = folder.appendingPathComponent(String(format: "part-%03d.m4a", chunks.count + 1))
                writer = try ChunkWriter(url: url, startTime: time, sampleRate: sampleRate)
                chunks.append(Chunk(url: url, offset: max(0, seconds - start)))
            }
            try await writer?.append(buffer)
            if let duration, duration > 0 {
                progress(min(1, (seconds - start) / duration))
            }
        }
        if reader.status == .failed { throw reader.error ?? AudioChunkerError.unreadable }
        try await writer?.finish()
        guard !chunks.isEmpty else { throw AudioChunkerError.noAudioTrack }
        return chunks
    }

    /// Whether the downloaded file can go to Groq as it is when it cannot be converted.
    static func canUploadDirectly(_ url: URL) -> Bool {
        guard url.pathExtension == "m4a",
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return false }
        return size <= uploadLimit
    }
}

/// Writes one part as AAC in an `.m4a` file.
private final class ChunkWriter {
    let start: Double
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    init(url: URL, startTime: CMTime, sampleRate: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        // An unsupported combination raises an exception when the input is created.
        if !writer.canApply(outputSettings: settings, forMediaType: .audio) {
            settings.removeValue(forKey: AVEncoderBitRateKey)
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw AudioChunkerError.encoderUnavailable
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AudioChunkerError.encoderUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AudioChunkerError.encoderUnavailable }
        writer.startSession(atSourceTime: startTime)
        self.writer = writer
        self.input = input
        start = startTime.isNumeric ? startTime.seconds : 0
    }

    func append(_ buffer: CMSampleBuffer) async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? AudioChunkerError.encoderUnavailable }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard input.append(buffer) else { throw writer.error ?? AudioChunkerError.encoderUnavailable }
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? AudioChunkerError.encoderUnavailable }
    }
}
