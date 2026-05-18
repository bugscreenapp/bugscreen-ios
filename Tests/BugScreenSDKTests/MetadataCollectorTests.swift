import XCTest
@testable import BugScreenSDK

/// Tests for MetadataCollector functionality.
final class MetadataCollectorTests: XCTestCase {

    // MARK: - Basic Collection Tests

    func testCollectMetadataReturnsDictionary() {
        let metadata = MetadataCollector.collect()

        XCTAssertFalse(metadata.isEmpty, "Metadata should not be empty")
    }

    func testCollectMetadataWithCustomData() {
        let customData = TestHelpers.sampleCustomData
        let metadata = MetadataCollector.collect(customData: customData)

        XCTAssertEqual(metadata[MetadataKeys.customData] as? [String: String], customData)
    }

    // MARK: - Device Information Tests

    func testDeviceFieldNotEmpty() {
        let metadata = MetadataCollector.collect()

        let device = metadata[MetadataKeys.device] as? String
        XCTAssertNotNil(device)
        XCTAssertFalse(device!.isEmpty)
    }

    func testManufacturerIsApple() {
        let metadata = MetadataCollector.collect()

        XCTAssertEqual(metadata[MetadataKeys.manufacturer] as? String, "Apple")
    }

    func testModelFieldNotEmpty() {
        let metadata = MetadataCollector.collect()

        let model = metadata[MetadataKeys.model] as? String
        XCTAssertNotNil(model)
        XCTAssertFalse(model!.isEmpty)
    }

    func testOSVersionNotEmpty() {
        let metadata = MetadataCollector.collect()

        let osVersion = metadata[MetadataKeys.osVersion] as? String
        XCTAssertNotNil(osVersion)
        XCTAssertFalse(osVersion!.isEmpty)
        XCTAssertTrue(osVersion!.contains("."))
    }

    // MARK: - App Information Tests

    func testAppVersionNotEmpty() {
        let metadata = MetadataCollector.collect()

        let appVersion = metadata[MetadataKeys.appVersion] as? String
        XCTAssertNotNil(appVersion)
        XCTAssertFalse(appVersion!.isEmpty)
    }

    func testAppBuildNumberNotEmpty() {
        let metadata = MetadataCollector.collect()

        let appBuildNumber = metadata[MetadataKeys.appBuildNumber] as? String
        XCTAssertNotNil(appBuildNumber)
        XCTAssertFalse(appBuildNumber!.isEmpty)
    }

    func testBundleIdentifierNotEmpty() {
        let metadata = MetadataCollector.collect()

        let bundleIdentifier = metadata[MetadataKeys.bundleIdentifier] as? String
        XCTAssertNotNil(bundleIdentifier)
        XCTAssertFalse(bundleIdentifier!.isEmpty)
    }

    // MARK: - Display Information Tests

    func testScreenScaleFormat() {
        let metadata = MetadataCollector.collect()

        let screenScale = metadata[MetadataKeys.screenScale] as? String
        XCTAssertNotNil(screenScale)
        XCTAssertTrue(screenScale!.hasSuffix("x"))
        XCTAssertTrue(screenScale!.contains("."))
    }

    func testScreenDimensionsPositive() {
        let metadata = MetadataCollector.collect()

        let widthPoints = metadata[MetadataKeys.screenWidthPoints] as? Int
        let heightPoints = metadata[MetadataKeys.screenHeightPoints] as? Int
        let widthPixels = metadata[MetadataKeys.screenWidthPixels] as? Int
        let heightPixels = metadata[MetadataKeys.screenHeightPixels] as? Int
        XCTAssertNotNil(widthPoints)
        XCTAssertNotNil(heightPoints)
        XCTAssertNotNil(widthPixels)
        XCTAssertNotNil(heightPixels)
        XCTAssertGreaterThan(widthPoints!, 0)
        XCTAssertGreaterThan(heightPoints!, 0)
        XCTAssertGreaterThanOrEqual(widthPixels!, widthPoints!)
        XCTAssertGreaterThanOrEqual(heightPixels!, heightPoints!)
    }

    // MARK: - System Information Tests

    func testTotalMemoryFormatted() {
        let metadata = MetadataCollector.collect()

        let totalMemory = metadata[MetadataKeys.totalMemory] as? String
        XCTAssertNotNil(totalMemory)
        XCTAssertFalse(totalMemory!.isEmpty)
    }

    func testAvailableMemoryFormatted() {
        let metadata = MetadataCollector.collect()

        let available = metadata[MetadataKeys.availableMemory] as? String
        XCTAssertNotNil(available)
        XCTAssertFalse(available!.isEmpty)
    }

    func testLocaleNotEmpty() {
        let metadata = MetadataCollector.collect()

        let locale = metadata[MetadataKeys.locale] as? String
        XCTAssertNotNil(locale)
        XCTAssertFalse(locale!.isEmpty)
    }

    // MARK: - Field Presence

    func testStandardKeysPresent() {
        let metadata = MetadataCollector.collect()

        let expected: Set<String> = [
            MetadataKeys.device, MetadataKeys.manufacturer, MetadataKeys.model, MetadataKeys.osVersion,
            MetadataKeys.appVersion, MetadataKeys.appBuildNumber, MetadataKeys.bundleIdentifier,
            MetadataKeys.screenWidthPoints, MetadataKeys.screenHeightPoints,
            MetadataKeys.screenWidthPixels, MetadataKeys.screenHeightPixels,
            MetadataKeys.screenScale,
            MetadataKeys.totalMemory, MetadataKeys.availableMemory, MetadataKeys.locale
        ]
        XCTAssertTrue(expected.isSubset(of: Set(metadata.keys)))
    }

    func testBugscreenVersionNotOnTheWire() {
        // Android does not send an SDK version field; iOS now matches.
        let metadata = MetadataCollector.collect()
        XCTAssertNil(metadata["bugscreenVersion"])
        XCTAssertNil(metadata["BugScreen SDK"])
    }

    // MARK: - Custom Data Tests

    func testNilCustomDataOmitsKey() {
        let metadata = MetadataCollector.collect(customData: nil)

        XCTAssertNil(metadata[MetadataKeys.customData])
    }

    func testEmptyCustomDataIsPreserved() {
        let metadata = MetadataCollector.collect(customData: [:])

        XCTAssertNotNil(metadata[MetadataKeys.customData])
        XCTAssertEqual((metadata[MetadataKeys.customData] as? [String: String])?.isEmpty, true)
    }

    func testCustomDataPreservesValues() {
        let customData: [String: String] = [
            "key1": "value1",
            "key2": "value2",
            "key3": "value3"
        ]
        let metadata = MetadataCollector.collect(customData: customData)

        XCTAssertEqual(metadata[MetadataKeys.customData] as? [String: String], customData)
    }

    // MARK: - JSON Serialization

    func testMetadataIsValidJSONObject() {
        let metadata = MetadataCollector.collect(customData: TestHelpers.sampleCustomData)

        XCTAssertTrue(JSONSerialization.isValidJSONObject(metadata))
    }

    func testMetadataRoundTripsThroughJSON() throws {
        let metadata = MetadataCollector.collect(customData: TestHelpers.sampleCustomData)

        let data = try JSONSerialization.data(withJSONObject: metadata)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?[MetadataKeys.device] as? String, metadata[MetadataKeys.device] as? String)
        XCTAssertEqual(decoded?[MetadataKeys.manufacturer] as? String, "Apple")
        XCTAssertEqual(
            decoded?[MetadataKeys.customData] as? [String: String],
            TestHelpers.sampleCustomData
        )
    }
}
