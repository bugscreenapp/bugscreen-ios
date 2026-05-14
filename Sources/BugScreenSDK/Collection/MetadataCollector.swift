import Foundation
import UIKit

/// Generic key/value metadata payload sent with a bug report.
///
/// The backend accepts arbitrary keys (`additionalProperties: true`) and each
/// platform sets the ones it cares about — no need to keep iOS and Android in
/// lockstep on field names.
internal typealias BugReportMetadata = [String: Any]

/// Wire keys for the metadata payload. Must match the Android SDK where the field is shared.
internal enum MetadataKeys {
    static let device = "device"
    static let manufacturer = "manufacturer"
    static let model = "model"
    static let osVersion = "osVersion"
    static let appVersion = "appVersion"
    static let appBuildNumber = "appBuildNumber"
    static let bundleIdentifier = "bundleIdentifier"
    static let screenResolution = "screenResolution"
    static let screenScale = "screenScale"
    static let screenWidth = "screenWidth"
    static let screenHeight = "screenHeight"
    static let totalMemory = "totalMemory"
    static let availableMemory = "availableMemory"
    static let locale = "locale"
    static let customData = "customData"
}

internal enum MetadataCollector {

    static func collect(customData: [String: String]? = nil) -> BugReportMetadata {
        let bounds = UIScreen.main.bounds
        let model = deviceModel()
        var metadata: BugReportMetadata = [
            MetadataKeys.device: "Apple \(model)",
            MetadataKeys.manufacturer: "Apple",
            MetadataKeys.model: model,
            MetadataKeys.osVersion: UIDevice.current.systemVersion,
            MetadataKeys.appVersion: appVersion(),
            MetadataKeys.appBuildNumber: buildNumber(),
            MetadataKeys.bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            MetadataKeys.screenResolution: screenResolution(),
            MetadataKeys.screenScale: "\(UIScreen.main.scale)x",
            MetadataKeys.screenWidth: Int(bounds.width),
            MetadataKeys.screenHeight: Int(bounds.height),
            MetadataKeys.totalMemory: ProcessInfo.processInfo.physicalMemory,
            MetadataKeys.availableMemory: availableMemory(),
            MetadataKeys.locale: Locale.current.identifier
        ]
        if let customData = customData {
            metadata[MetadataKeys.customData] = customData
        }
        return metadata
    }

    // MARK: - Device Information

    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let mirror = Mirror(reflecting: systemInfo.machine)
        let identifier = mirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else {
                return identifier
            }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }

        return identifier
    }

    // MARK: - App Information

    private static func appVersion() -> String {
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static func buildNumber() -> String {
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    // MARK: - Display Information

    private static func screenResolution() -> String {
        let bounds = UIScreen.main.nativeBounds
        return "\(Int(bounds.width)) x \(Int(bounds.height))"
    }

    // MARK: - System Information

    private static func availableMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        if result == KERN_SUCCESS {
            let totalMemory = ProcessInfo.processInfo.physicalMemory
            let usedMemory = UInt64(info.resident_size)
            return totalMemory > usedMemory ? totalMemory - usedMemory : 0
        }

        return 0
    }
}
