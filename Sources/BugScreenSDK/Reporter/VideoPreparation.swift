import AVFoundation
import Foundation
import UIKit

struct PreparedVideo {
    let file: URL
    let poster: UIImage
    let durationSeconds: Double
}

struct ReportMediaOrder {
    let isVideo: Bool
    let index: Int
}

enum PickedAttachment {
    case image(UIImage)
    case video(URL)
    case unavailable(VideoPreparationError)
}

struct VideoAttachmentLimits: Codable {
    let maxSizeBytes: Int64
    let maxDurationSeconds: Double

    var isValid: Bool {
        maxSizeBytes > 0 && maxDurationSeconds.isFinite && maxDurationSeconds > 0
    }
}

enum VideoPreparation {
    static func poster(for source: URL) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 224, height: 224)
            return UIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))
        }.value
    }

    static func copySelection(_ url: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("bugscreen-video-source-\(UUID().uuidString).mov")
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw VideoPreparationError.empty }
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: copy)
            throw error as? VideoPreparationError ?? .importing
        }
        return copy
    }

    static func prepare(_ source: URL, limits: VideoAttachmentLimits) async throws -> PreparedVideo {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("bugscreen-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        do {
            try Task.checkCancellation()
            guard limits.isValid else { throw VideoPreparationError.configuration }
            let asset = try await sourceAsset(source, limits: limits)
            do {
                try await VideoEncoder.encode(asset, to: output)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as VideoPreparationError {
                throw failure
            } catch {
                throw VideoPreparationError.encoding
            }
            let preparedDuration = try await validatePrepared(output, limits: limits)
            let poster: UIImage
            do { poster = try await self.poster(for: output) } catch { throw VideoPreparationError.preview }
            return PreparedVideo(file: output, poster: poster, durationSeconds: preparedDuration)
        } catch {
            try? FileManager.default.removeItem(at: output)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Internal generated-media path: validate the finished H.264 file without changing capture quality.
    static func adoptGenerated(_ source: URL, limits: VideoAttachmentLimits, retaining ownership: AnyObject? = nil,
                               check: @escaping () throws -> Void) async throws -> PreparedVideo
    {
        try check()
        guard limits.isValid else { throw VideoPreparationError.configuration }
        _ = try await sourceAsset(source, limits: limits)
        let duration = try await validatePrepared(source, limits: limits)
        let asset = AVURLAsset(url: source)
        guard try await asset.loadTracks(withMediaType: .audio).isEmpty else { throw VideoPreparationError.encoding }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoPreparationError.decoding }
        reader.add(output)
        guard reader.startReading() else { throw VideoPreparationError.decoding }
        let deadline = Date().addingTimeInterval(30)
        var decoded = 0
        do {
            while true {
                try check()
                try Task.checkCancellation()
                guard Date() < deadline else { throw VideoPreparationError.processing }
                let found = autoreleasepool { output.copyNextSampleBuffer() != nil }
                if !found { break }
                decoded += 1
            }
            guard decoded > 0, reader.status == .completed else { throw VideoPreparationError.decoding }
        } catch { reader.cancelReading(); throw error }
        try check()
        let poster = try await GeneratedVideoPoster(source: source, retaining: ownership).image(check: check)
        try check()
        return PreparedVideo(file: source, poster: poster, durationSeconds: duration)
    }

    private static func sourceAsset(_ source: URL, limits: VideoAttachmentLimits) async throws -> AVURLAsset {
        do {
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw VideoPreparationError.empty }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 12) ?? Data()
            guard header.count == 12,
                  ["ftyp", "moov", "wide", "free", "mdat"].contains(String(bytes: header[4 ..< 8], encoding: .utf8) ?? "")
            else { throw VideoPreparationError.container }
        } catch {
            throw error as? VideoPreparationError ?? .importing
        }
        let asset = AVURLAsset(url: source)
        let duration: Double
        let tracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration).seconds
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch { throw VideoPreparationError.decoding }
        try validateDuration(duration, limits: limits)
        guard tracks.count == 1 else { throw VideoPreparationError.videoTrack }
        return asset
    }

    private static func validatePrepared(_ output: URL, limits: VideoAttachmentLimits) async throws -> Double {
        let result = AVURLAsset(url: output)
        let preparedDuration = try await result.load(.duration).seconds
        let preparedSize = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard preparedSize > 0 else { throw VideoPreparationError.empty }
        if Int64(preparedSize) > limits.maxSizeBytes {
            throw VideoPreparationError.tooLarge(actual: Int64(preparedSize), limit: limits.maxSizeBytes)
        }
        try validateDuration(preparedDuration, limits: limits)
        let preparedTracks = try await result.loadTracks(withMediaType: .video)
        guard preparedTracks.count == 1 else { throw VideoPreparationError.videoTrack }
        let formats = try await preparedTracks[0].load(.formatDescriptions)
        guard formats.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
        else { throw VideoPreparationError.encoding }
        return preparedDuration
    }

    private static func validateDuration(_ duration: Double, limits: VideoAttachmentLimits) throws {
        guard duration.isFinite, duration > 0 else { throw VideoPreparationError.duration }
        if duration > limits.maxDurationSeconds {
            throw VideoPreparationError.tooLong(actual: duration, limit: limits.maxDurationSeconds)
        }
    }
}

/// Only generated clips use this cancellation/deadline wrapper; imported media keeps its existing path.
private final class GeneratedVideoPoster: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage, Error>?
    private var timer: DispatchSourceTimer?

    private var ownership: AnyObject?

    init(source: URL, retaining ownership: AnyObject?) {
        self.ownership = ownership
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 224, height: 224)
    }

    func image(check: @escaping () throws -> Void) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let deadline = Date().addingTimeInterval(15)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            self.timer = timer
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in
                do {
                    try check()
                    guard Date() < deadline else { throw VideoPreparationError.preview }
                } catch {
                    self?.generator.cancelAllCGImageGeneration()
                    self?.finish(.failure(error))
                }
            }
            timer.resume()
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [self] _, image, _, result, _ in
                if result == .succeeded, let image {
                    finish(.success(UIImage(cgImage: image)))
                } else { finish(.failure(VideoPreparationError.preview)) }
                lock.lock()
                ownership = nil
                lock.unlock()
            }
        }
    }

    private func finish(_ result: Result<UIImage, Error>) {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        timer?.cancel()
        value?.resume(with: result)
    }
}
