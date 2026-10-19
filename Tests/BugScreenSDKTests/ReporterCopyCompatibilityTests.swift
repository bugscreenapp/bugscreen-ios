@testable import BugScreenSDK
import Foundation
import XCTest

final class ReporterCopyCompatibilityTests: XCTestCase {
    // Frozen shapes from ios/v1.2.0 and ios/v1.7.0:
    // sdks/ios/Sources/BugScreenSDK/Models/APIModels.swift (JSONDecoder).
    private struct Legacy12: Decodable { let appId: String; let showBranding: Bool }
    private struct Legacy17: Decodable { let appId: String; let showBranding: Bool; let reportTypes: [String]?; let severityEnabled: Bool? }

    func testLegacyDecodersIgnoreCopyWithoutChangingTheirSettings() throws {
        let data = Data(#"{"appId":"app-1","showBranding":false,"reportTypes":["Question","Suggestion"],"severityEnabled":false,"reporterCopy":{"title":"Feedback","submitLabel":"Send"},"futureField":42}"#
            .utf8)
        let old = try JSONDecoder().decode(Legacy12.self, from: data)
        XCTAssertEqual(old.appId, "app-1")
        XCTAssertFalse(old.showBranding)
        let recent = try JSONDecoder().decode(Legacy17.self, from: data)
        XCTAssertEqual(recent.reportTypes, ["Question", "Suggestion"])
        XCTAssertEqual(recent.severityEnabled, false)
    }

    func testLegacyResponseAndMissingKeysDefaultButMalformedSuppliedCopyFails() throws {
        let legacy = try JSONDecoder().decode(SdkConfig.self, from: Data(#"{"appId":"app-1","showBranding":false}"#.utf8))
        XCTAssertNil(legacy.reporterCopy)
        let partial = try JSONDecoder().decode(
            ReporterCopy.self,
            from: Data(#"{"title":"<b>Feedback</b> {name} 100%","futureKey":42}"#.utf8)
        )
        XCTAssertEqual(partial.title, "<b>Feedback</b> {name} 100%")
        XCTAssertEqual(partial.submitLabel, "Create ticket")
        for json in ["null", "[]", "42", #"{"title":null}"#, #"{"title":42}"#, #"{"title":""}"#, #"{"title":"hello\nworld"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ReporterCopy.self, from: Data(json.utf8)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            SdkConfig.self,
            from: Data(#"{"appId":"app-1","showBranding":false,"reporterCopy":null}"#.utf8)
        ))
    }

    func testUnicodeLimitsAndNormalization() throws {
        XCTAssertEqual(try ReporterCopy.fromValues(["title": " Cafe\u{301} "]).title, "Café")
        XCTAssertEqual(try ReporterCopy.fromValues(["title": String(repeating: "🙂", count: 60)]).title, String(repeating: "🙂", count: 60))
        XCTAssertThrowsError(try ReporterCopy.fromValues(["title": String(repeating: "🙂", count: 61)]))
    }

    func testTypeHeadingAndSubmitLabelAcceptSixtyCodePointsAndRejectSixtyOne() throws {
        let value = String(repeating: "🙂", count: 60)
        let copy = try ReporterCopy.fromValues(["typeLabel": value, "submitLabel": value])
        XCTAssertEqual(copy.typeLabel, value)
        XCTAssertEqual(copy.submitLabel, value)
        for key in ["typeLabel", "submitLabel"] {
            XCTAssertThrowsError(try ReporterCopy.fromValues([key: value + "🙂"]))
        }
    }
}
