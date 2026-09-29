import XCTest

/// Runs against the bundled sample vault (a fresh install).
final class NavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFolderOpensAsFolderAndNoteOpensAsDocument() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Notes"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Notes"].waitForExistence(timeout: 5), "Tapping a folder should show its contents")
        XCTAssertFalse(app.staticTexts["Couldn’t Open Note"].exists)

        app.buttons["Markdown Showcase"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["A relative image path:"].waitForExistence(timeout: 5)
                      || app.staticTexts["Lists"].waitForExistence(timeout: 5),
                      "Tapping a note should render it")
    }
}
