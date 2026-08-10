@testable import BugScreenSDK
import PhotosUI
import XCTest

/// `PHPickerViewController` can't be driven from a unit test, so the settings that carry
/// behaviour are asserted on the configuration the reporter hands it (CAP-004).
final class PhotoPickerConfigurationTests: XCTestCase {
    /// The default, `.default`, returns results in *library* order — which silently reorders a
    /// set of screenshots taken in the sequence the bug unfolded. Ordering is the behaviour,
    /// not a picker nicety.
    ///
    /// This assertion reads a field off the configuration it just built, so on its own it only
    /// proves we still pass `.ordered` — not that PHPicker honours it. The honouring was
    /// confirmed on a simulator: two photos tapped right-then-left (library order left-then-right)
    /// came back badged 1 and 2 in tap order and attached in that order. Numbered badges only
    /// render in `.ordered`, so they are the observable proof the flag reached the OS. Keep this
    /// test as the regression tripwire for the line being deleted; re-verify on device if the
    /// picker configuration is reworked.
    func testPicksInTheOrderTheTesterTapped() {
        XCTAssertEqual(PhotoPickerConfiguration.make(selectionLimit: 4).selection, .ordered)
    }

    /// The caller passes the *remaining* slots, so the picker stops the tester at the cap
    /// rather than accepting a selection the form would trim afterwards.
    func testCarriesTheRemainingSlotsAsTheSelectionLimit() {
        XCTAssertEqual(PhotoPickerConfiguration.make(selectionLimit: 2).selectionLimit, 2)
        XCTAssertEqual(PhotoPickerConfiguration.make(selectionLimit: 4).selectionLimit, 4)
    }

    // The `.images` filter is deliberately not asserted: `PHPickerFilter` is not Equatable, so
    // the only available check passes for `.videos` too — a test that cannot fail for any
    // regression it claims to catch is worse than none.
}
