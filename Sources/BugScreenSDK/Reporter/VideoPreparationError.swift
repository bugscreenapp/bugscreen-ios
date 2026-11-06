import Foundation

enum VideoPreparationError: LocalizedError {
    case configuration, importing, container, empty, decoding, videoTrack, resolution, duration, encoding, preview, processing
    case recording(String)
    case tooLong(actual: Double, limit: Double)
    case tooLarge(actual: Int64, limit: Int64)

    var errorDescription: String? {
        switch self {
        case let .recording(reason):
            SDKStrings.recordingFailure(reason)
        case let .tooLong(actual, limit):
            SDKStrings.videoDurationExceeded(actual, limit: limit)
        case let .tooLarge(actual, limit):
            SDKStrings.videoSizeExceeded(actual, limit: limit)
        default:
            SDKStrings.videoFailure(key)
        }
    }

    private var key: String {
        switch self {
        case .recording: "processing"
        case .configuration: "configuration"
        case .importing: "import"
        case .container: "container"
        case .empty: "empty"
        case .decoding: "decode"
        case .videoTrack: "track"
        case .resolution: "resolution"
        case .duration: "duration"
        case .encoding: "encoding"
        case .preview: "preview"
        case .processing, .tooLong, .tooLarge: "processing"
        }
    }
}
