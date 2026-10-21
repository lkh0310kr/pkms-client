import XCTest

/// Runs against the bundled sample vault (a fresh install), which includes `Places.map`.
final class MapUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testMapShowsSavedPlacesAndFindsOne() {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Places"].firstMatch.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let chip = button(app, startingWith: "Seoul")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Group chips should show")
        attach(app, "map")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Tower")
        let saved = button(app, startingWith: "N Seoul Tower")
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "Saved places should be suggested")
        attach(app, "search")
        saved.tap()

        XCTAssertTrue(app.buttons["Directions"].waitForExistence(timeout: 5), "Selecting a place shows its card")
        XCTAssertTrue(app.staticTexts["서울 용산구 남산공원길 105"].exists)
        attach(app, "card")

        app.buttons["Edit"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Place"].waitForExistence(timeout: 3))
        attach(app, "editor")
        app.buttons["Cancel"].tap()

        app.buttons["Favorites"].tap()
        let cafes = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Cafés")).firstMatch
        XCTAssertTrue(cafes.waitForExistence(timeout: 3), "Favorites lists the top-level folders")
        attach(app, "favorites")
        cafes.tap()
        XCTAssertTrue(button(app, startingWith: "Hongdae Coffee").waitForExistence(timeout: 3), "A folder lists its places")

        // Nest a new folder inside Cafés.
        app.buttons["More"].tap()
        app.buttons["New Folder"].tap()
        app.textFields["Name"].typeText("Roasteries")
        app.buttons["Create"].tap()
        XCTAssertTrue(button(app, startingWith: "Roasteries").waitForExistence(timeout: 3))
        attach(app, "folder")
    }

    /// Rows and chips read as one element, e.g. "Seoul, 3" or "N Seoul Tower, 서울 용산구 …".
    private func button(_ app: XCUIApplication, startingWith title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1.0)  // let the map settle
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
