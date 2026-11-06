import VideoToolbox

/// Hardware enumeration metadata is optional; modern iOS can enforce hardware at session creation instead.
enum HardwareRecordingEncoder: Equatable {
    case requiredHardware
    case identifiedHardware(String)

    static func current() -> HardwareRecordingEncoder? {
        let canRequireHardware = if #available(iOS 17.4, *) {
            true
        } else {
            false
        }
        return select(canRequireHardware: canRequireHardware) {
            var values: CFArray?
            guard VTCopyVideoEncoderList(nil, &values) == noErr else { return [] }
            return values as? [[String: Any]] ?? []
        }
    }

    static func select(canRequireHardware: Bool, encoders: () -> [[String: Any]]) -> HardwareRecordingEncoder? {
        if canRequireHardware { return .requiredHardware }
        guard let encoder = encoders().first(where: {
            ($0[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == kCMVideoCodecType_H264 &&
                ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true &&
                $0[kVTVideoEncoderList_EncoderID as String] is String
        }), let identifier = encoder[kVTVideoEncoderList_EncoderID as String] as? String else { return nil }
        return .identifiedHardware(identifier)
    }

    var specification: [CFString: Any]? {
        switch self {
        case .requiredHardware:
            if #available(iOS 17.4, *) { return [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                                                 kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] }
            return nil
        case let .identifiedHardware(identifier):
            return [kVTVideoEncoderSpecification_EncoderID: identifier]
        }
    }

    func verifies(selectedID: String?, usingHardware: Bool?) -> Bool {
        switch self {
        case .requiredHardware: usingHardware == true
        case let .identifiedHardware(identifier): selectedID == identifier
        }
    }
}
