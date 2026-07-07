@testable import BugScreenSDK
import XCTest

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

        for (key, value) in customData {
            XCTAssertEqual(metadata[key] as? String, value)
        }
    }

    // MARK: - Device Information Tests

    func testDeviceFieldNotEmpty() throws {
        let metadata = MetadataCollector.collect()

        let device = metadata[MetadataKeys.device] as? String
        XCTAssertNotNil(device)
        XCTAssertFalse(try XCTUnwrap(device?.isEmpty))
    }

    func testManufacturerIsApple() {
        let metadata = MetadataCollector.collect()

        XCTAssertEqual(metadata[MetadataKeys.manufacturer] as? String, "Apple")
    }

    func testModelFieldNotEmpty() throws {
        let metadata = MetadataCollector.collect()

        let model = metadata[MetadataKeys.model] as? String
        XCTAssertNotNil(model)
        XCTAssertFalse(try XCTUnwrap(model?.isEmpty))
    }

    func testOSVersionNotEmpty() throws {
        let metadata = MetadataCollector.collect()

        let osVersion = metadata[MetadataKeys.osVersion] as? String
        XCTAssertNotNil(osVersion)
        XCTAssertFalse(try XCTUnwrap(osVersion?.isEmpty))
        XCTAssertTrue(try XCTUnwrap(osVersion?.contains(".")))
    }

    // MARK: - App Information Tests

    func testAppVersionNotEmpty() throws {
        let metadata = MetadataCollector.collect()

        let appVersion = metadata[MetadataKeys.appVersion] as? String
        XCTAssertNotNil(appVersion)
        XCTAssertFalse(try XCTUnwrap(appVersion?.isEmpty))
    }

    func testAppBuildNumberNotEmpty() throws {
        let metadata = MetadataCollector.collect()

        let appBuildNumber = metadata[MetadataKeys.appBuildNumber] as? String
        XCTAssertNotNil(appBuildNumber)
        XCTAssertFalse(try XCTUnwrap(appBuildNumber?.isEmpty))
    }

    func testBundleIdentifierNotEmpty() throws {
        let metadata = MetadataCollector.collect()

        let bundleIdentifier = metadata[MetadataKeys.bundleIdentifier] as? String
        XCTAssertNotNil(bundleIdentifier)
        XCTAssertFalse(try XCTUnwrap(bundleIdentifier?.isEmpty))
    }

    // MARK: - Display Information Tests

    func testScreenScaleFormat() throws {
        let metadata = MetadataCollector.collect()

        let screenScale = metadata[MetadataKeys.screenScale] as? String
        XCTAssertNotNil(screenScale)
        XCTAssertTrue(try XCTUnwrap(screenScale?.hasSuffix("x")))
        XCTAssertTrue(try XCTUnwrap(screenScale?.contains(".")))
    }

    func testScreenDimensionsPositive() throws {
        let metadata = MetadataCollector.collect()

        let widthPoints = metadata[MetadataKeys.screenWidthPoints] as? Int
        let heightPoints = metadata[MetadataKeys.screenHeightPoints] as? Int
        let widthPixels = metadata[MetadataKeys.screenWidthPixels] as? Int
        let heightPixels = metadata[MetadataKeys.screenHeightPixels] as? Int
        XCTAssertNotNil(widthPoints)
        XCTAssertNotNil(heightPoints)
        XCTAssertNotNil(widthPixels)
        XCTAssertNotNil(heightPixels)
        XCTAssertGreaterThan(try XCTUnwrap(widthPoints), 0)
        XCTAssertGreaterThan(try XCTUnwrap(heightPoints), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(widthPixels), try XCTUnwrap(widthPoints))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(heightPixels), try XCTUnwrap(heightPoints))
    }

    // MARK: - System Information Tests

    func testTotalMemoryFormatted() throws {
        let metadata = MetadataCollector.collect()

        let totalMemory = metadata[MetadataKeys.totalMemory] as? String
        XCTAssertNotNil(totalMemory)
        XCTAssertFalse(try XCTUnwrap(totalMemory?.isEmpty))
    }

    func testAvailableMemoryFormatted() throws {
        let metadata = MetadataCollector.collect()

        let available = metadata[MetadataKeys.availableMemory] as? String
        XCTAssertNotNil(available)
        XCTAssertFalse(try XCTUnwrap(available?.isEmpty))
    }

    func testLocaleNotEmpty() throws {
        let metadata = MetadataCollector.collect()

        let locale = metadata[MetadataKeys.locale] as? String
        XCTAssertNotNil(locale)
        XCTAssertFalse(try XCTUnwrap(locale?.isEmpty))
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
            MetadataKeys.totalMemory, MetadataKeys.availableMemory, MetadataKeys.locale,
            MetadataKeys.appearance,
        ]
        XCTAssertTrue(expected.isSubset(of: Set(metadata.keys)))
    }

    // MARK: - Appearance Tests

    func testAppearanceIsOneOfKnownValues() {
        let metadata = MetadataCollector.collect()

        let appearance = metadata[MetadataKeys.appearance] as? String
        XCTAssertNotNil(appearance)
        XCTAssertTrue(["Dark", "Light", "Unknown"].contains(appearance ?? ""))
    }

    func testAppearanceNameMapsEachStyle() {
        // Direct mapping test — the only way to exercise the Unknown branch,
        // which a simulator's resolved trait collection won't produce.
        XCTAssertEqual(MetadataCollector.appearanceName(.dark), "Dark")
        XCTAssertEqual(MetadataCollector.appearanceName(.light), "Light")
        XCTAssertEqual(MetadataCollector.appearanceName(.unspecified), "Unknown")
    }

    func testBugscreenVersionNotOnTheWire() {
        // Android does not send an SDK version field; iOS now matches.
        let metadata = MetadataCollector.collect()
        XCTAssertNil(metadata["bugscreenVersion"])
        XCTAssertNil(metadata["BugScreen SDK"])
    }

    // MARK: - Custom Data Tests

    func testNilCustomDataAddsNothing() {
        let baseline = MetadataCollector.collect()
        let metadata = MetadataCollector.collect(customData: nil)

        XCTAssertEqual(Set(metadata.keys), Set(baseline.keys))
    }

    func testEmptyCustomDataAddsNothing() {
        let baseline = MetadataCollector.collect()
        let metadata = MetadataCollector.collect(customData: [:])

        XCTAssertEqual(Set(metadata.keys), Set(baseline.keys))
    }

    func testCustomDataFlattenedAlongsideStandardKeys() {
        let customData: [String: String] = [
            "key1": "value1",
            "key2": "value2",
            "key3": "value3",
        ]
        let metadata = MetadataCollector.collect(customData: customData)

        XCTAssertEqual(metadata["key1"] as? String, "value1")
        XCTAssertEqual(metadata["key2"] as? String, "value2")
        XCTAssertEqual(metadata["key3"] as? String, "value3")
        XCTAssertNotNil(metadata[MetadataKeys.device])
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
        for (key, value) in TestHelpers.sampleCustomData {
            XCTAssertEqual(decoded?[key] as? String, value)
        }
    }
}
