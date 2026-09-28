import XCTest
@testable import FolioCore

final class EditorPreferencesTests: XCTestCase {
    func testValidEditorSizeIsPreserved() {
        XCTAssertEqual(EditorPreferences.clampedPointSize(18), 18)
    }
    func testOutOfRangeSizesAreClamped() {
        XCTAssertEqual(EditorPreferences.clampedPointSize(-10), 11)
        XCTAssertEqual(EditorPreferences.clampedPointSize(1000), 32)
    }
    func testInvalidNumbersUseSafeDefault() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(EditorPreferences.clampedPointSize(value), EditorPreferences.defaultPointSize)
        }
    }
}
