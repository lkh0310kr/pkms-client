import XCTest

/// Runs against the bundled sample vault (a fresh install).
final class EditorUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateNoteWithSlashCommandAndChecklist() {
        let app = XCUIApplication()
        app.launch()

        // New note opens straight into the editor with the keyboard up.
        app.buttons["New Note"].firstMatch.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        dismissKeyboardTip(app)
        XCTAssertTrue(app.buttons["Bold"].waitForExistence(timeout: 5), "Formatting bar should appear above the keyboard")

        editor.typeText("Groceries\n/to")
        XCTAssertTrue(app.buttons["To-do List"].waitForExistence(timeout: 3), "Typing / should open the block menu")
        attach(app, "slash-menu")
        app.buttons["To-do List"].tap()
        editor.typeText("Milk\nEggs\n\nDone for today")
        attach(app, "editing")

        XCTAssertEqual(editor.value as? String, "# Groceries\n- [ ] Milk\n- [ ] Eggs\n\nDone for today")

        app.buttons["Done"].tap()

        // The note is rendered and took its name from the first line.
        XCTAssertTrue(app.staticTexts["Milk"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5), "Untitled note should be renamed from its title")

        // Text after the list stays a separate paragraph.
        XCTAssertTrue(app.staticTexts["Done for today"].exists)
        // Checkboxes work in reading mode.
        app.buttons["Not completed"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Completed"].waitForExistence(timeout: 3))
        attach(app, "rendered")
    }

    @MainActor
    func testPageLinkSuggestions() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["New Note"].firstMatch.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        dismissKeyboardTip(app)

        editor.typeText("Links\nSee [[Show")
        XCTAssertTrue(app.buttons["Markdown Showcase"].waitForExistence(timeout: 3), "[[ should suggest pages")
        attach(app, "page-suggestions")
        app.buttons["Markdown Showcase"].tap()
        XCTAssertEqual(editor.value as? String, "# Links\nSee [[Markdown Showcase]]")
    }

    /// The simulator keyboard shows a one-time "slide to type" tip that blocks input.
    @MainActor
    private func dismissKeyboardTip(_ app: XCUIApplication) {
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 2) { tip.tap() }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 0.6)  // let transitions settle
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
