import CoreImage
import Foundation
import ReplayKit
import VideoToolbox

final class ScreenRecordingEncoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.bugscreen.recording", qos: .utility)
    private let gate = NSLock()
    private var accepting = false
    private var wantsAcceptance = false
    private var inFlight = 0
    private var lastAdmission = -Double.infinity
    private var generation = 0
    private let profile: RecordingProfile
    private let options: ScreenRecordingOptions
    private var maximumDuration: Double
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var size: CGSize = .zero
    private var sourceSize: CGSize = .zero
    private var orientation: Int = 1
    private var ring: EncodedRecordingBuffer
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let failure: @Sendable (ScreenRecordingUnavailableReason) -> Void

    init(options: ScreenRecordingOptions, failure: @escaping @Sendable (ScreenRecordingUnavailableReason) -> Void) {
        self.options = options
        maximumDuration = Double(options.durationSeconds)
        profile = RecordingProfile(options.quality)
        ring = EncodedRecordingBuffer(duration: Double(options.durationSeconds), byteLimit: profile.byteLimit, budget: .shared)
        self.failure = failure
    }

    func beginExplicit() {
        gate.lock()
        maximumDuration = 60
        gate.unlock()
        resume(explicit: true)
    }

    func resume(explicit: Bool = false) {
        gate.lock()
        generation += 1
        let epoch = generation
        wantsAcceptance = true
        accepting = false
        gate.unlock()
        queue.async {
            self.reset()
            if explicit {
                self.sampleLock.lock()
                self.ring = EncodedRecordingBuffer(duration: 60, byteLimit: self.profile.byteLimit, budget: .shared)
                self.sampleLock.unlock()
            }
            self.gate.lock()
            if self.generation == epoch, self.wantsAcceptance {
                self.lastAdmission = -.infinity
                self.accepting = true
            }
            self.gate.unlock()
        }
    }

    func stop() {
        gate.lock()
        accepting = false
        wantsAcceptance = false
        generation += 1
        gate.unlock()
        queue.async { self.reset() }
    }

    func freeze() -> FrozenRecording {
        gate.lock()
        accepting = false
        wantsAcceptance = false
        let duration = maximumDuration
        gate.unlock()
        let frozen = FrozenRecording(maximumDuration: duration,
                                     triggerTimestamp: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        queue.async {
            if let session = self.session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
            self.sampleLock.lock()
            let samples = self.ring.take()
            self.sampleLock.unlock()
            self.reset()
            frozen.install(samples)
        }
        return frozen
    }

    func accept(_ sample: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        gate.lock()
        guard accepting, inFlight < 2, timestamp.isFinite,
              timestamp - lastAdmission >= 1 / Double(profile.framesPerSecond) - 0.0001
        else { gate.unlock(); return }
        // Fail closed if this platform does not supply ReplayKit timestamps in the host-clock domain.
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard timestamp <= hostTime + 0.1, hostTime - timestamp < 5 else {
            accepting = false
            gate.unlock()
            failure(.unsupportedProfile)
            return
        }
        inFlight += 1
        lastAdmission = timestamp
        let epoch = generation
        gate.unlock()
        queue.async {
            self.gate.lock()
            let current = epoch == self.generation
            self.gate.unlock()
            if current { self.encode(sample) }
            self.gate.lock()
            self.inFlight -= 1
            self.gate.unlock()
        }
    }

    private func encode(_ sample: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let currentSize = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        let currentOrientation = (CMGetAttachment(
            sample,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber)?.intValue ?? 1
        if session == nil || sourceSize != currentSize || currentOrientation != orientation {
            reset()
            sourceSize = currentSize
            orientation = currentOrientation
            let oriented = CIImage(cvPixelBuffer: image).oriented(forExifOrientation: Int32(orientation))
            guard setup(size: oriented.extent.size) else { failure(.unsupportedProfile); return }
        }
        guard let pool, let session else { return }
        var output: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                                                                         [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary,
                                                                         &output)
        guard status == kCVReturnSuccess, let output else { return }
        let original = CIImage(cvPixelBuffer: image).oriented(forExifOrientation: Int32(orientation))
        let normalized = original.transformed(by: CGAffineTransform(translationX: -original.extent.minX, y: -original.extent.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(
            scaleX: size.width / original.extent.width,
            y: size.height / original.extent.height
        ))
        context.render(scaled, to: output)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let result = VTCompressionSessionEncodeFrame(session, imageBuffer: output, presentationTimeStamp: pts,
                                                     duration: CMTime(value: 1, timescale: CMTimeScale(profile.framesPerSecond)),
                                                     frameProperties: nil,
                                                     sourceFrameRefcon: nil, infoFlagsOut: nil)
        if result != noErr { failure(.encodingFailed) }
    }

    private func setup(size source: CGSize) -> Bool {
        guard let selection = HardwareRecordingEncoder.current(), let specification = selection.specification else { return false }
        let (width, height) = profile.dimensions(source)
        size = CGSize(width: width, height: height)
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                           kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { reference, _, status, _, sample in
                guard let reference else { return }
                let owner = Unmanaged<ScreenRecordingEncoder>.fromOpaque(reference)
                    .takeUnretainedValue()
                guard status == noErr,
                      let sample else { if status != noErr { owner.failure(.encodingFailed) }; return }
                // VideoToolbox can invoke this synchronously or on its own queue. Keep ring access serialized.
                owner.receive(sample)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { return false }
        let properties: [CFString: Any] = [kVTCompressionPropertyKey_RealTime: true,
                                           kVTCompressionPropertyKey_AllowFrameReordering: false,
                                           kVTCompressionPropertyKey_AverageBitRate: profile.bitrate,
                                           kVTCompressionPropertyKey_ExpectedFrameRate: profile.framesPerSecond,
                                           kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
                                           kVTCompressionPropertyKey_MaxKeyFrameInterval: profile.framesPerSecond,
                                           kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel]
        guard VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr,
              VTCompressionSessionPrepareToEncodeFrames(session) == noErr,
              CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 2] as CFDictionary,
                                      attributes as CFDictionary, &pool) == kCVReturnSuccess else { reset(); return false }
        let usingHardware: Bool?
        if #available(iOS 17.4, *) {
            usingHardware = Self.property(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool
        } else { usingHardware = nil }
        guard selection.verifies(selectedID: Self.property(session, kVTCompressionPropertyKey_EncoderID) as? String,
                                 usingHardware: usingHardware) else { reset(); return false }
        return true
    }

    private static func property(_ session: VTCompressionSession, _ key: CFString) -> CFTypeRef? {
        var value: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value) == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    private let sampleLock = NSLock()
    private func receive(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        let duration = CMSampleBufferGetDuration(sample).seconds
        let item = RecordedSample(buffer: sample, timestamp: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                                  duration: duration.isFinite && duration > 0 ? duration : 1 / Double(profile.framesPerSecond),
                                  bytes: CMSampleBufferGetTotalSampleSize(sample), keyframe: keyframe)
        sampleLock.lock()
        ring.append(item)
        sampleLock.unlock()
    }

    private func reset() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        pool = nil
        sampleLock.lock()
        ring.clear()
        sampleLock.unlock()
    }
}
