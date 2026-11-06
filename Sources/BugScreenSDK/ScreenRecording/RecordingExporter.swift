import AVFoundation
import Foundation

final class FrozenRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var samples: [RecordedSample]?
    private var ready = false
    private let maximumDuration: Double
    private let triggerTimestamp: Double

    init(maximumDuration: Double, triggerTimestamp: Double) {
        self.maximumDuration = maximumDuration
        self.triggerTimestamp = triggerTimestamp
    }

    func install(_ value: [RecordedSample]) {
        lock.lock()
        if !cancelled { samples = value }
        ready = true
        lock.unlock()
    }

    private func takeIfReady() -> [RecordedSample]? {
        lock.lock()
        defer { lock.unlock() }
        guard ready else { return nil }
        let value = samples ?? []
        samples = nil
        return value
    }

    func cancel() {
        lock.lock()
        cancelled = true
        samples = nil
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let invalid = cancelled
        lock.unlock()
        if invalid { throw CancellationError() }
    }

    func prepare(limits: VideoAttachmentLimits?) async throws -> PreparedVideo {
        guard let limits, limits.isValid else { throw VideoPreparationError.configuration }
        let deadline = Date().addingTimeInterval(30)
        var result: [RecordedSample]?
        while result == nil {
            try check()
            result = takeIfReady()
            guard Date() < deadline else { throw VideoPreparationError.processing }
            if result == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        let captured = result ?? []
        try check()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) { [self] in
                try await RecordingExportAdmission.shared.run { lease in
                    try check()
                    let effectiveDuration = min(maximumDuration, limits.maxDurationSeconds)
                    let selected = EncodedRecordingBuffer.selection(
                        captured,
                        maximumDuration: effectiveDuration - 2 / 60000,
                        endingAt: triggerTimestamp
                    )
                    let effectiveLimits = VideoAttachmentLimits(maxSizeBytes: limits.maxSizeBytes, maxDurationSeconds: effectiveDuration)
                    guard !selected.isEmpty else { throw VideoPreparationError.recording("empty") }
                    let url = try RecordingFileStore.newFile()
                    do {
                        try await RecordingExporter.write(selected, to: url, retaining: lease, check: check)
                        try check()
                        let video = try await VideoPreparation.adoptGenerated(url, limits: effectiveLimits, retaining: lease, check: check)
                        try check()
                        return video
                    } catch {
                        try? FileManager.default.removeItem(at: url)
                        throw error
                    }
                }
            }.value
        }, onCancel: { self.cancel() })
    }
}

enum RecordingFileStore {
    private static let initialization: Void = cleanAbandoned()

    static func initialize() {
        _ = initialization
    }

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bugscreen-recent-video", isDirectory: true)
    }

    static func cleanAbandoned() {
        // Only our export directory; imported media and visible draft attachments have separate owners.
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func newFile() throws -> URL {
        initialize()
        var folder = directory
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        return folder.appendingPathComponent("\(UUID().uuidString).mp4")
    }
}

enum RecordingExporter {
    static func write(_ samples: [RecordedSample], to url: URL, retaining lease: RecordingExportLease? = nil,
                      check: @escaping () throws -> Void) async throws
    {
        guard let first = samples.first,
              let format = CMSampleBufferGetFormatDescription(first.buffer) else { throw VideoPreparationError.empty }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieTimeScale = 60000
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = 60000
        guard writer.canAdd(input) else { throw VideoPreparationError.encoding }
        writer.add(input)
        guard writer.startWriting() else { throw VideoPreparationError.encoding }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(30)
        do {
            for sample in samples {
                try check()
                while !input.isReadyForMoreMediaData {
                    try check()
                    guard writer.status == .writing, Date() < deadline else { throw VideoPreparationError.processing }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                var timing = CMSampleTimingInfo(duration: CMTime(seconds: sample.duration, preferredTimescale: 60000),
                                                presentationTimeStamp: CMTime(
                                                    seconds: sample.timestamp - first.timestamp,
                                                    preferredTimescale: 60000
                                                ),
                                                decodeTimeStamp: .invalid)
                var rebased: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(
                          allocator: kCFAllocatorDefault,
                          sampleBuffer: sample.buffer,
                          sampleTimingEntryCount: 1,
                          sampleTimingArray: &timing,
                          sampleBufferOut: &rebased
                      ) == noErr,
                      let rebased, input.append(rebased) else { throw VideoPreparationError.encoding }
            }
            input.markAsFinished()
            try await finish(writer, retaining: lease, check: check)
            try check()
            guard writer.status == .completed else { throw VideoPreparationError.encoding }
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    private static func finish(_ writer: AVAssetWriter, retaining lease: RecordingExportLease?,
                               check: @escaping () throws -> Void) async throws
    {
        let completion = RecordingWriteCompletion(writer: writer, retaining: lease)
        try await withCheckedThrowingContinuation { continuation in
            completion.begin(continuation)
            let deadline = Date().addingTimeInterval(30)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            completion.timer = timer
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak completion] in
                do {
                    try check()
                    guard Date() < deadline else { throw VideoPreparationError.processing }
                } catch {
                    completion?.writer.cancelWriting()
                    completion?.finish(.failure(error))
                }
            }
            timer.resume()
            writer.finishWriting {
                completion.finish(completion.writer.status == .completed ? .success(()) : .failure(VideoPreparationError.encoding))
                completion.releaseCallbackOwnership()
            }
        }
    }
}

private final class RecordingWriteCompletion: @unchecked Sendable {
    // Writing has ended before this owner is shared; AVFoundation supports cancelling finalization.
    let writer: AVAssetWriter
    init(writer: AVAssetWriter, retaining lease: RecordingExportLease?) {
        self.writer = writer
        self.lease = lease
    }

    private var lease: RecordingExportLease?

    func releaseCallbackOwnership() {
        lock.lock()
        lease = nil
        lock.unlock()
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    var timer: DispatchSourceTimer?

    func begin(_ value: CheckedContinuation<Void, Error>) {
        continuation = value
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        timer?.cancel()
        value?.resume(with: result)
    }
}
