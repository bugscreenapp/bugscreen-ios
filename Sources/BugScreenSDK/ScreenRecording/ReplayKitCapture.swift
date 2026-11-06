import ReplayKit

@MainActor
protocol RecordingCaptureSource: AnyObject {
    var isAvailable: Bool { get }
    var isRecording: Bool { get }
    var delegate: RPScreenRecorderDelegate? { get set }
    func start(handler: @escaping (CMSampleBuffer, RPSampleBufferType, Error?) -> Void, completion: @escaping @Sendable (Error?) -> Void)
    func stop(completion: @escaping @Sendable (Error?) -> Void)
}

@MainActor
final class ReplayKitCapture: RecordingCaptureSource {
    private let recorder = RPScreenRecorder.shared()
    var isAvailable: Bool {
        recorder.isAvailable
    }

    var isRecording: Bool {
        recorder.isRecording
    }

    var delegate: RPScreenRecorderDelegate? {
        get { recorder.delegate }
        set { recorder.delegate = newValue }
    }

    func start(handler: @escaping (CMSampleBuffer, RPSampleBufferType, Error?) -> Void, completion: @escaping @Sendable (Error?) -> Void) {
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false
        recorder.startCapture(handler: handler, completionHandler: completion)
    }

    func stop(completion: @escaping @Sendable (Error?) -> Void) {
        recorder.stopCapture(handler: completion)
    }
}
