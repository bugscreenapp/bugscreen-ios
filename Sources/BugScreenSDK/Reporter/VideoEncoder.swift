import AVFoundation
import Foundation

/// Owns one file export; the serial queue confines reader/writer state and cancellation.
final class VideoEncoder: @unchecked Sendable {
    static let averageBitrate = 4_000_000

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let streams: [(AVAssetReaderOutput, AVAssetWriterInput)]
    private let queue = DispatchQueue(label: "app.bugscreen.video-encoding", qos: .userInitiated)
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var finished = false
    private var remaining: Int

    static func encode(_ asset: AVAsset, to output: URL) async throws {
        try Task.checkCancellation()
        let videos = try await asset.loadTracks(withMediaType: .video)
        guard videos.count == 1 else { throw VideoPreparationError.videoTrack }
        let track = videos[0]
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw VideoPreparationError.resolution
        }
        let scale = min(1, 1280 / max(size.width, size.height), 720 / min(size.width, size.height))
        let settings = videoSettings(size: size, scale: scale)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d,
                                                 tx: transform.tx * scale, ty: transform.ty * scale)
        var streams: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(videoOutput, videoInput)]
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            let formats = try await audio.load(.formatDescriptions)
            guard let description = formats.first,
                  let info = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            else {
                throw VideoPreparationError.decoding
            }
            let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            audioOutput.alwaysCopiesSampleData = false
            var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                           AVSampleRateKey: info.pointee.mSampleRate,
                                           AVNumberOfChannelsKey: info.pointee.mChannelsPerFrame,
                                           AVEncoderBitRateKey: 128_000]
            var layoutSize = 0
            if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) {
                settings[AVChannelLayoutKey] = Data(bytes: layout, count: layoutSize)
            }
            streams.append((audioOutput, AVAssetWriterInput(mediaType: .audio, outputSettings: settings)))
        }
        for (source, target) in streams {
            guard reader.canAdd(source), writer.canAdd(target) else { throw VideoPreparationError.encoding }
            reader.add(source)
            writer.add(target)
        }
        let encoder = VideoEncoder(reader: reader, writer: writer, streams: streams)
        try await withTaskCancellationHandler(operation: { try await encoder.run() }, onCancel: { encoder.cancel() })
    }

    static func videoSettings(size: CGSize, scale: CGFloat) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264,
         AVVideoWidthKey: max(2, Int(size.width * scale) / 2 * 2),
         AVVideoHeightKey: max(2, Int(size.height * scale) / 2 * 2),
         AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
         AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: averageBitrate]]
    }

    private init(reader: AVAssetReader, writer: AVAssetWriter, streams: [(AVAssetReaderOutput, AVAssetWriterInput)]) {
        self.reader = reader
        self.writer = writer
        self.streams = streams
        remaining = streams.count
    }

    private func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                guard !self.cancelled else { self.fail(CancellationError()); return }
                guard self.writer.startWriting() else {
                    self.fail(VideoPreparationError.encoding); return
                }
                guard self.reader.startReading() else {
                    self.fail(VideoPreparationError.decoding); return
                }
                self.writer.startSession(atSourceTime: .zero)
                for (source, target) in self.streams {
                    target.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.pump(source, to: target) }
                }
            }
        }
    }

    private func pump(_ source: AVAssetReaderOutput, to target: AVAssetWriterInput) {
        guard !finished else { return }
        while target.isReadyForMoreMediaData {
            let sample = autoreleasepool { source.copyNextSampleBuffer() }
            guard let sample else {
                target.markAsFinished()
                if reader.status == .failed { fail(VideoPreparationError.decoding); return }
                remaining -= 1
                if remaining == 0 { finish() }
                return
            }
            guard target.append(sample) else { fail(VideoPreparationError.encoding); return }
        }
    }

    private func finish() {
        guard reader.status == .completed else { fail(VideoPreparationError.decoding); return }
        writer.finishWriting { [self] in
            queue.async {
                guard !self.finished else { return }
                guard self.writer.status == .completed else { self.fail(VideoPreparationError.encoding); return }
                self.finished = true
                self.continuation?.resume()
                self.continuation = nil
            }
        }
    }

    private func cancel() {
        queue.async {
            self.cancelled = true
            if self.continuation != nil { self.fail(CancellationError()) }
        }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        reader.cancelReading()
        writer.cancelWriting()
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
