import Foundation
import UIKit

/// Generic key/value metadata payload sent with a bug report.
///
/// Keys double as display labels rendered verbatim by the backend (GitHub
/// markdown body, Jira ADF). Units are baked into the key where ambiguity is
/// possible (`Screen Width (points)` vs `Screen Width (pixels)`).
internal typealias BugReportMetadata = [String: Any]

/// Wire keys for the metadata payload. Keys are human-readable display labels.
internal enum MetadataKeys {
    static let device = "Device"
    static let manufacturer = "Manufacturer"
    static let model = "Model"
    static let osVersion = "OS Version"
    static let appVersion = "App Version"
    static let appBuildNumber = "App Build Number"
    static let bundleIdentifier = "Bundle Identifier"
    static let screenWidthPoints = "Screen Width (points)"
    static let screenHeightPoints = "Screen Height (points)"
    static let screenWidthPixels = "Screen Width (pixels)"
    static let screenHeightPixels = "Screen Height (pixels)"
    static let screenScale = "Screen Scale"
    static let totalMemory = "Total Memory"
    static let availableMemory = "Available Memory"
    static let locale = "Locale"
    static let customData = "Custom Data"
}

internal enum MetadataCollector {

    static func collect(customData: [String: String]? = nil) -> BugReportMetadata {
        let bounds = UIScreen.main.bounds
        let nativeBounds = UIScreen.main.nativeBounds
        let model = deviceModel()
        var metadata: BugReportMetadata = [
            MetadataKeys.device: "Apple \(model)",
            MetadataKeys.manufacturer: "Apple",
            MetadataKeys.model: model,
            MetadataKeys.osVersion: UIDevice.current.systemVersion,
            MetadataKeys.appVersion: appVersion(),
            MetadataKeys.appBuildNumber: buildNumber(),
            MetadataKeys.bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            MetadataKeys.screenWidthPoints: Int(bounds.width),
            MetadataKeys.screenHeightPoints: Int(bounds.height),
            MetadataKeys.screenWidthPixels: Int(nativeBounds.width),
            MetadataKeys.screenHeightPixels: Int(nativeBounds.height),
            MetadataKeys.screenScale: "\(UIScreen.main.scale)x",
            MetadataKeys.totalMemory: formatBytes(ProcessInfo.processInfo.physicalMemory),
            MetadataKeys.availableMemory: formatBytes(availableMemory()),
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

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.2f KB", kb) }
        let mb = kb / 1024.0
        if mb < 1024 { return String(format: "%.2f MB", mb) }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
    }
}
